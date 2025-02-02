use crate::{PortalInternalMessage, PortalMessage, TcpPortalRecvProcessor};
use core::time::Duration;
use ockam_core::compat::{boxed::Box, net::SocketAddr};
use ockam_core::{async_trait, Decodable};
use ockam_core::{Address, Any, Result, Route, Routed, Worker};
use ockam_node::Context;
use ockam_transport_core::TransportError;
use tokio::io::AsyncWriteExt;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::TcpStream;
use tracing::{debug, info, trace, warn};

/// Enumerate all `TcpPortalWorker` states
///
/// Possible state transitions are:
///
/// `Outlet`: `SendPong` -> `Initialized`
/// `Inlet`: `SendPing` -> `ReceivePong` -> `Initialized`
#[derive(Clone)]
enum State {
    SendPing { ping_route: Route },
    SendPong { pong_route: Route },
    ReceivePong,
    Initialized,
}

/// Enumerate all portal types
#[derive(Debug)]
enum TypeName {
    Inlet,
    Outlet,
}

/// A TCP Portal worker
///
/// A TCP Portal worker is responsible for managing the life-cycle of
/// a portal connection and is created by
/// [`TcpInletListenProcessor::process`](crate::TcpInletListenProcessor)
/// after a new connection has been accepted.
pub(crate) struct TcpPortalWorker {
    state: State,
    tx: Option<OwnedWriteHalf>,
    rx: Option<OwnedReadHalf>,
    peer: SocketAddr,
    internal_address: Address,
    remote_address: Address,
    receiver_address: Address,
    remote_route: Option<Route>,
    is_disconnecting: bool,
    type_name: TypeName,
}

impl TcpPortalWorker {
    /// Start a new `TcpPortalWorker` of type [`TypeName::Inlet`]
    pub(crate) async fn start_new_inlet(
        ctx: &Context,
        stream: TcpStream,
        peer: SocketAddr,
        ping_route: Route,
    ) -> Result<Address> {
        Self::start(
            ctx,
            peer,
            State::SendPing { ping_route },
            Some(stream),
            TypeName::Inlet,
        )
        .await
    }

    /// Start a new `TcpPortalWorker` of type [`TypeName::Outlet`]
    pub(crate) async fn start_new_outlet(
        ctx: &Context,
        peer: SocketAddr,
        pong_route: Route,
    ) -> Result<Address> {
        Self::start(
            ctx,
            peer,
            State::SendPong { pong_route },
            None,
            TypeName::Outlet,
        )
        .await
    }

    /// Start a new `TcpPortalWorker`
    async fn start(
        ctx: &Context,
        peer: SocketAddr,
        state: State,
        stream: Option<TcpStream>,
        type_name: TypeName,
    ) -> Result<Address> {
        let internal_addr = Address::random_local();
        let remote_addr = Address::random_local();
        let receiver_address = Address::random_local();

        info!(
            "Creating new {:?} at internal: {}, remote: {}",
            type_name, internal_addr, remote_addr
        );

        let (rx, tx) = match stream {
            Some(s) => {
                let (rx, tx) = s.into_split();
                (Some(rx), Some(tx))
            }
            None => (None, None),
        };

        let sender = Self {
            state,
            tx,
            rx,
            peer,
            internal_address: internal_addr.clone(),
            remote_address: remote_addr.clone(),
            remote_route: None,
            receiver_address,
            is_disconnecting: false,
            type_name,
        };

        ctx.start_worker(vec![internal_addr, remote_addr.clone()], sender)
            .await?;

        Ok(remote_addr)
    }
}

enum DisconnectionReason {
    FailedTx,
    FailedRx,
    Remote,
}

impl TcpPortalWorker {
    fn clone_state(&self) -> State {
        self.state.clone()
    }

    /// Start a `TcpPortalRecvProcessor`
    async fn start_receiver(&mut self, ctx: &Context, onward_route: Route) -> Result<()> {
        if let Some(rx) = self.rx.take() {
            let receiver =
                TcpPortalRecvProcessor::new(rx, self.internal_address.clone(), onward_route);
            ctx.start_processor(self.receiver_address.clone(), receiver)
                .await
        } else {
            Err(TransportError::PortalInvalidState.into())
        }
    }

    async fn notify_remote_about_disconnection(&mut self, ctx: &Context) -> Result<()> {
        // Notify the other end
        if let Some(remote_route) = self.remote_route.take() {
            ctx.send_from_address(
                remote_route,
                PortalMessage::Disconnect,
                self.remote_address.clone(),
            )
            .await?;

            debug!(
                "Notified the other side from {:?} at: {} about connection drop",
                self.type_name, self.internal_address
            );
        }

        // Avoiding race condition when both inlet and outlet connections
        // are dropped at the same time. In this case we want to wait for the `Disconnect`
        // message from the other side to reach our worker, before we shut it down which
        // leads to errors (destination Worker is already stopped)
        // TODO: Remove when we have better way to handle race condition
        ctx.sleep(Duration::from_secs(1)).await;

        Ok(())
    }

    async fn stop_receiver(&self, ctx: &Context) -> Result<()> {
        // Avoiding race condition when both inlet and outlet connections
        // are dropped at the same time. In this case Processor may stop itself
        // while we had `Disconnect` message from the other side. Let it stop itself,
        // but recheck that by calling `stop_processor` and ignoring the error
        // TODO: Remove when we have better way to handle race condition
        ctx.sleep(Duration::from_secs(1)).await;

        if ctx
            .stop_processor(self.receiver_address.clone())
            .await
            .is_ok()
        {
            debug!(
                "{:?} at: {} stopped receiver due to connection drop",
                self.type_name, self.internal_address
            );
        }

        Ok(())
    }

    /// Start the portal disconnection process
    async fn start_disconnection(
        &mut self,
        ctx: &Context,
        reason: DisconnectionReason,
    ) -> Result<()> {
        self.is_disconnecting = true;

        match reason {
            DisconnectionReason::FailedTx => {
                self.notify_remote_about_disconnection(ctx).await?;
            }
            DisconnectionReason::FailedRx => {
                self.notify_remote_about_disconnection(ctx).await?;
                self.stop_receiver(ctx).await?;
            }
            DisconnectionReason::Remote => {
                self.stop_receiver(ctx).await?;
            }
        }

        ctx.stop_worker(self.internal_address.clone()).await?;

        info!(
            "{:?} at: {} stopped due to connection drop",
            self.type_name, self.internal_address
        );

        Ok(())
    }

    async fn handle_send_ping(&self, ctx: &Context, ping_route: Route) -> Result<State> {
        // Force creation of Outlet on the other side
        ctx.send_from_address(ping_route, PortalMessage::Ping, self.remote_address.clone())
            .await?;

        debug!("Inlet at: {} sent ping", self.internal_address);

        Ok(State::ReceivePong)
    }

    async fn handle_send_pong(&mut self, ctx: &Context, pong_route: Route) -> Result<State> {
        // Respond to Inlet
        ctx.send_from_address(
            pong_route.clone(),
            PortalMessage::Pong,
            self.remote_address.clone(),
        )
        .await?;

        if self.tx.is_none() {
            let stream = TcpStream::connect(self.peer)
                .await
                .map_err(TransportError::from)?;
            let (rx, tx) = stream.into_split();
            self.tx = Some(tx);
            self.rx = Some(rx);

            self.start_receiver(ctx, pong_route.clone()).await?;

            debug!(
                "Outlet at: {} successfully connected",
                self.internal_address
            );
        }

        debug!("Outlet at: {} sent pong", self.internal_address);

        self.remote_route = Some(pong_route);
        Ok(State::Initialized)
    }
}

#[async_trait]
impl Worker for TcpPortalWorker {
    type Context = Context;
    type Message = Any;

    async fn initialize(&mut self, ctx: &mut Self::Context) -> Result<()> {
        let state = self.clone_state();

        match state {
            State::SendPing { ping_route } => {
                self.state = self.handle_send_ping(ctx, ping_route.clone()).await?;
            }
            State::SendPong { pong_route } => {
                self.state = self.handle_send_pong(ctx, pong_route.clone()).await?;
            }
            State::ReceivePong | State::Initialized { .. } => {
                return Err(TransportError::PortalInvalidState.into())
            }
        }

        Ok(())
    }

    // TcpSendWorker will receive messages from the TcpRouter to send
    // across the TcpStream to our friend
    async fn handle_message(&mut self, ctx: &mut Context, msg: Routed<Any>) -> Result<()> {
        if self.is_disconnecting {
            return Ok(());
        }

        // Remove our own address from the route so the other end
        // knows what to do with the incoming message
        let mut onward_route = msg.onward_route();
        let recipient = onward_route.step()?;

        let return_route = msg.return_route();

        if onward_route.next().is_ok() {
            return Err(TransportError::UnknownRoute.into());
        }

        let state = self.clone_state();

        match state {
            State::ReceivePong => {
                if recipient == self.internal_address {
                    return Err(TransportError::PortalInvalidState.into());
                }

                let msg = PortalMessage::decode(msg.payload())?;

                if let PortalMessage::Pong = msg {
                } else {
                    return Err(TransportError::Protocol.into());
                }

                self.start_receiver(ctx, return_route.clone()).await?;

                debug!("Inlet at: {} received pong", self.internal_address);

                self.remote_route = Some(return_route);
                self.state = State::Initialized;
            }
            State::Initialized => {
                if recipient == self.internal_address {
                    trace!(
                        "{:?} at: {} received internal tcp packet",
                        self.type_name,
                        self.internal_address
                    );

                    let msg = PortalInternalMessage::decode(msg.payload())?;

                    match msg {
                        PortalInternalMessage::Disconnect => {
                            info!(
                                "Tcp stream was dropped for {:?} at: {}",
                                self.type_name, self.internal_address
                            );
                            self.start_disconnection(ctx, DisconnectionReason::FailedRx)
                                .await?;
                        }
                    }
                } else {
                    trace!(
                        "{:?} at: {} received remote tcp packet",
                        self.type_name,
                        self.internal_address
                    );

                    // Send to Tcp stream
                    let msg = PortalMessage::decode(msg.payload())?;

                    match msg {
                        PortalMessage::Payload(payload) => {
                            if let Some(tx) = &mut self.tx {
                                match tx.write_all(&payload).await {
                                    Ok(()) => {}
                                    Err(err) => {
                                        warn!(
                                            "Failed to send message to peer {} with error: {}",
                                            self.peer, err
                                        );
                                        self.start_disconnection(
                                            ctx,
                                            DisconnectionReason::FailedTx,
                                        )
                                        .await?;
                                    }
                                }
                            } else {
                                return Err(TransportError::PortalInvalidState.into());
                            }
                        }
                        PortalMessage::Disconnect => {
                            self.start_disconnection(ctx, DisconnectionReason::Remote)
                                .await?;
                        }
                        PortalMessage::Ping | PortalMessage::Pong => {
                            return Err(TransportError::Protocol.into());
                        }
                    }
                }
            }
            State::SendPing { .. } | State::SendPong { .. } => {
                return Err(TransportError::PortalInvalidState.into())
            }
        };

        Ok(())
    }
}
