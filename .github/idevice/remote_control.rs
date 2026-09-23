use std::{
    ffi::{CStr, c_char},
    ptr::null_mut,
    sync::Mutex,
    time::Duration,
};

use idevice::{
    IdeviceError, ReadWrite, RsdService,
    core_device::{
        ButtonState, CallInfoBlob, DisplayServiceClient, HevcDepacketizer, IndigoHidClient,
        MainKeyboardService, OrientationServiceClient, RotationDirection, RtpPacket,
        TOUCHSCREEN_STATE_CONTACT, TOUCHSCREEN_STATE_RELEASE, UniversalHidServiceClient,
        build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters,
        build_start_video_parameters,
    },
    springboardservices::{InterfaceOrientation, SpringBoardServicesClient},
    tcp::handle::UdpSocketHandle,
};
use uuid::Uuid;

use crate::{
    IdeviceFfiError, core_device_proxy::AdapterHandle, ffi_err, rsd::RsdHandshakeHandle,
    run_sync_local,
};

const CLIENT_SUPPORTED_FEATURES: u64 = 140;

/// Owns the CoreDevice clients needed to view and control one paired device.
pub struct RemoteControlClientHandle {
    universal_hid: Mutex<RemoteUniversalHidState>,
    buttons: Mutex<IndigoHidClient<Box<dyn ReadWrite>>>,
    orientation: Mutex<OrientationServiceClient<Box<dyn ReadWrite>>>,
    springboard: Mutex<Option<SpringBoardServicesClient>>,
    display: Mutex<DisplayServiceClient<Box<dyn ReadWrite>>>,
    video: Mutex<RemoteVideoState>,
    _audio_udp: UdpSocketHandle,
}

struct RemoteUniversalHidState {
    client: UniversalHidServiceClient<Box<dyn ReadWrite>>,
    keyboard: Option<MainKeyboardService>,
}

struct RemoteVideoState {
    socket: UdpSocketHandle,
    depacketizer: HevcDepacketizer,
}

struct ScreenMediaSession {
    display: DisplayServiceClient<Box<dyn ReadWrite>>,
    audio_udp: UdpSocketHandle,
    video_udp: UdpSocketHandle,
}

async fn start_screen_media_session(
    adapter: &mut idevice::tcp::handle::AdapterHandle,
    handshake: &mut idevice::rsd::RsdHandshake,
) -> Result<ScreenMediaSession, IdeviceError> {
    let mut display = DisplayServiceClient::connect_rsd(adapter, handshake).await?;
    let audio_udp = adapter.bind_udp(0).await?;
    let video_udp = adapter.bind_udp(0).await?;

    let receiver_ip = adapter.host_ip().to_string();
    let sender_ip = adapter.peer_ip().to_string();
    let client_session_id = Uuid::new_v4();
    let call_info = CallInfoBlob {
        call_id: 0,
        client_version: 1,
        device_type: "Mac17,7".into(),
        framework_version: "2205.3.1".into(),
        os_version: "25F71".into(),
        device_name: None,
        audio_device_uid: None,
    };

    let audio_call_id = Uuid::new_v4().to_string().to_uppercase();
    let audio_offer = build_screen_audio_offer(&audio_call_id, &call_info)?;
    let audio_parameters = build_start_audio_parameters(
        &receiver_ip,
        audio_udp.local_port(),
        &sender_ip,
        50000,
        audio_offer,
        CLIENT_SUPPORTED_FEATURES,
        client_session_id,
    );
    display.start_media_stream(audio_parameters).await?;

    let video_call_id = Uuid::new_v4().to_string().to_uppercase();
    let ssrc = Uuid::new_v4().as_u128() as u32;
    let video_offer = build_screen_video_offer(&video_call_id, &call_info, ssrc)?;
    let video_parameters = build_start_video_parameters(
        &receiver_ip,
        video_udp.local_port(),
        &sender_ip,
        50001,
        video_offer,
        CLIENT_SUPPORTED_FEATURES,
        1,
        client_session_id,
    );
    display.start_media_stream(video_parameters).await?;

    Ok(ScreenMediaSession {
        display,
        audio_udp,
        video_udp,
    })
}

/// Opens the display-stream, touchscreen and hardware-button services.
/// The caller must keep `adapter` and `handshake` alive until this handle is freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_connect_rsd(
    adapter: *mut AdapterHandle,
    handshake: *mut RsdHandshakeHandle,
    out_handle: *mut *mut RemoteControlClientHandle,
) -> *mut IdeviceFfiError {
    if adapter.is_null() || handshake.is_null() || out_handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let result: Result<RemoteControlClientHandle, IdeviceError> = run_sync_local(async {
        let adapter = unsafe { &mut (*adapter).0 };
        let handshake = unsafe { &mut (*handshake).0 };

        let media = start_screen_media_session(adapter, handshake).await?;
        let mut universal_hid = UniversalHidServiceClient::connect_rsd(adapter, handshake).await?;
        let keyboard = universal_hid.create_main_keyboard().await.ok();
        if keyboard.is_some() {
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        let buttons = IndigoHidClient::connect_rsd(adapter, handshake).await?;
        let orientation = OrientationServiceClient::connect_rsd(adapter, handshake).await?;
        let springboard = SpringBoardServicesClient::connect_rsd(adapter, handshake)
            .await
            .ok();

        Ok(RemoteControlClientHandle {
            universal_hid: Mutex::new(RemoteUniversalHidState {
                client: universal_hid,
                keyboard,
            }),
            buttons: Mutex::new(buttons),
            orientation: Mutex::new(orientation),
            springboard: Mutex::new(springboard),
            display: Mutex::new(media.display),
            video: Mutex::new(RemoteVideoState {
                socket: media.video_udp,
                depacketizer: HevcDepacketizer::new(),
            }),
            _audio_udp: media.audio_udp,
        })
    });

    match result {
        Ok(handle) => {
            unsafe { *out_handle = Box::into_raw(Box::new(handle)) };
            null_mut()
        }
        Err(error) => ffi_err!(error),
    }
}

/// Receives one complete marker-closed HEVC access unit in Annex-B framing.
/// A timeout is not an error: `out_data` remains NULL and `out_len` is zero.
/// Free non-NULL data with `idevice_data_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_next_video_access_unit(
    handle: *mut RemoteControlClientHandle,
    timeout_ms: u64,
    out_data: *mut *mut u8,
    out_len: *mut usize,
    out_timestamp: *mut u32,
) -> *mut IdeviceFfiError {
    if handle.is_null() || out_data.is_null() || out_len.is_null() || out_timestamp.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    unsafe {
        *out_data = null_mut();
        *out_len = 0;
        *out_timestamp = 0;
    }

    let handle = unsafe { &*handle };
    let mut video = match handle.video.lock() {
        Ok(video) => video,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "video receiver lock poisoned".into()
            ));
        }
    };
    let timeout = Duration::from_millis(timeout_ms.max(1));

    loop {
        let datagram = match run_sync_local(async {
            tokio::time::timeout(timeout, video.socket.recv()).await
        }) {
            Ok(Ok(datagram)) => datagram,
            Ok(Err(error)) => return ffi_err!(IdeviceError::Socket(error)),
            Err(_) => return null_mut(),
        };
        let Some(packet) = RtpPacket::parse(&datagram.data) else {
            continue;
        };
        if packet.payload_type != 100 {
            continue;
        }
        let marker = packet.marker;
        let timestamp = packet.timestamp;
        video
            .depacketizer
            .push(packet.sequence_number, timestamp, packet.payload);
        if !marker {
            continue;
        }

        let bytes = video.depacketizer.take_output();
        if bytes.is_empty() {
            continue;
        }
        let mut bytes = bytes.into_boxed_slice();
        unsafe {
            *out_data = bytes.as_mut_ptr();
            *out_len = bytes.len();
            *out_timestamp = timestamp;
        }
        std::mem::forget(bytes);
        return null_mut();
    }
}

/// Returns whether a Bonjour remote-pairing authTag belongs to this pairing file.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_pairing_matches_service(
    pairing_file: *mut crate::rp_pairing_file::RpPairingFileHandle,
    service_identifier: *const c_char,
    auth_tag: *const c_char,
    out_matches: *mut bool,
) -> *mut IdeviceFfiError {
    if pairing_file.is_null()
        || service_identifier.is_null()
        || auth_tag.is_null()
        || out_matches.is_null()
    {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let service_identifier = match unsafe { CStr::from_ptr(service_identifier) }.to_str() {
        Ok(value) => value,
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };
    let auth_tag = match unsafe { CStr::from_ptr(auth_tag) }.to_str() {
        Ok(value) => value,
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };
    let pairing_file = unsafe { &(*pairing_file).0 };
    let matches = pairing_file.alt_irk().is_some_and(|alternate_irk| {
        idevice::remote_pairing::PeerDevice::validate_auth_tag(
            alternate_irk,
            service_identifier,
            auth_tag,
        )
    });
    unsafe { *out_matches = matches };
    null_mut()
}

/// Sends a tap in normalized coordinates, where each axis is 0...65535.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_tap(
    handle: *mut RemoteControlClientHandle,
    x: u16,
    y: u16,
) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let handle = unsafe { &*handle };
    let mut state = match handle.universal_hid.lock() {
        Ok(state) => state,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "touch client lock poisoned".into()
            ));
        }
    };
    match run_sync_local(state.client.tap(x, y)) {
        Ok(()) => null_mut(),
        Err(error) => ffi_err!(error),
    }
}

/// Sends a drag in normalized coordinates.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_drag(
    handle: *mut RemoteControlClientHandle,
    start_x: u16,
    start_y: u16,
    end_x: u16,
    end_y: u16,
    duration_ms: u64,
) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let handle = unsafe { &*handle };
    let mut state = match handle.universal_hid.lock() {
        Ok(state) => state,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "touch client lock poisoned".into()
            ));
        }
    };
    let steps = ((duration_ms / 16).clamp(2, 60)) as u32;
    let delay_ms = (duration_ms / u64::from(steps)).max(1);
    match run_sync_local(
        state
            .client
            .drag(start_x, start_y, end_x, end_y, steps, delay_ms),
    ) {
        Ok(()) => null_mut(),
        Err(error) => ffi_err!(error),
    }
}

/// Sends one live touchscreen transition: 0=down, 1=move, 2=up.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_touch(
    handle: *mut RemoteControlClientHandle,
    phase: u8,
    x: u16,
    y: u16,
) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let state = match phase {
        0 | 1 => TOUCHSCREEN_STATE_CONTACT,
        2 => TOUCHSCREEN_STATE_RELEASE,
        _ => return ffi_err!(IdeviceError::FfiInvalidArg),
    };
    let handle = unsafe { &*handle };
    let mut hid = match handle.universal_hid.lock() {
        Ok(hid) => hid,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "touch client lock poisoned".into()
            ));
        }
    };
    match run_sync_local(hid.client.send_touchscreen(state, x, y, None)) {
        Ok(()) => null_mut(),
        Err(error) => ffi_err!(error),
    }
}

/// Taps one HID Keyboard/Keypad usage with an optional USB HID modifier bitmap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_keyboard_tap(
    handle: *mut RemoteControlClientHandle,
    usage: u16,
    modifiers: u8,
) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let handle = unsafe { &*handle };
    let mut keyboard = match handle.buttons.lock() {
        Ok(keyboard) => keyboard,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "keyboard client lock poisoned".into()
            ));
        }
    };
    let result = run_sync_local(async {
        for bit in 0u8..8 {
            if modifiers & (1 << bit) != 0 {
                keyboard
                    .send_keyboard(0xE0 + u64::from(bit), ButtonState::Down)
                    .await?;
            }
        }
        keyboard
            .send_keyboard(u64::from(usage), ButtonState::Down)
            .await?;
        keyboard
            .send_keyboard(u64::from(usage), ButtonState::Up)
            .await?;
        for bit in (0u8..8).rev() {
            if modifiers & (1 << bit) != 0 {
                keyboard
                    .send_keyboard(0xE0 + u64::from(bit), ButtonState::Up)
                    .await?;
            }
        }
        tokio::time::sleep(Duration::from_millis(12)).await;
        Ok::<(), IdeviceError>(())
    });
    match result {
        Ok(()) => null_mut(),
        Err(error) => ffi_err!(error),
    }
}

/// Toggles whether the target displays its software keyboard.
///
/// The CoreDevice main-keyboard service represents an attached hardware
/// keyboard. Removing it allows iOS to present the software keyboard; creating
/// it again restores hardware-keyboard behavior.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_toggle_software_keyboard(
    handle: *mut RemoteControlClientHandle,
    out_visible: *mut bool,
) -> *mut IdeviceFfiError {
    if handle.is_null() || out_visible.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let handle = unsafe { &*handle };
    let mut state = match handle.universal_hid.lock() {
        Ok(state) => state,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "keyboard service lock poisoned".into()
            ));
        }
    };

    if let Some(mut keyboard) = state.keyboard.take() {
        match run_sync_local(state.client.remove_main_keyboard(&mut keyboard)) {
            Ok(()) => {
                unsafe { *out_visible = true };
                null_mut()
            }
            Err(error) => {
                state.keyboard = Some(keyboard);
                ffi_err!(IdeviceError::InternalError(error.to_string()))
            }
        }
    } else {
        match run_sync_local(state.client.create_main_keyboard()) {
            Ok(keyboard) => {
                state.keyboard = Some(keyboard);
                unsafe { *out_visible = false };
                null_mut()
            }
            Err(error) => ffi_err!(IdeviceError::InternalError(error.to_string())),
        }
    }
}

/// Reads the target's current SpringBoard interface orientation (0...4).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_get_orientation(
    handle: *mut RemoteControlClientHandle,
    out_orientation: *mut u8,
) -> *mut IdeviceFfiError {
    if handle.is_null() || out_orientation.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let handle = unsafe { &*handle };
    let mut springboard = match handle.springboard.lock() {
        Ok(springboard) => springboard,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "orientation client lock poisoned".into()
            ));
        }
    };
    let Some(springboard) = springboard.as_mut() else {
        return ffi_err!(IdeviceError::InternalError(
            "the remote orientation service is unavailable".into()
        ));
    };
    match run_sync_local(springboard.get_interface_orientation()) {
        Ok(orientation) => {
            let value = match orientation {
                InterfaceOrientation::Portrait => 1,
                InterfaceOrientation::PortraitUpsideDown => 2,
                InterfaceOrientation::LandscapeRight => 3,
                InterfaceOrientation::LandscapeLeft => 4,
                InterfaceOrientation::Unknown => 0,
            };
            unsafe { *out_orientation = value };
            null_mut()
        }
        Err(error) => ffi_err!(error),
    }
}

/// Rotates the target 90 degrees: 0 is left, 1 is right.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_rotate(
    handle: *mut RemoteControlClientHandle,
    direction: u8,
) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let direction = match direction {
        0 => RotationDirection::Left,
        1 => RotationDirection::Right,
        _ => return ffi_err!(IdeviceError::FfiInvalidArg),
    };
    let handle = unsafe { &*handle };
    let mut orientation = match handle.orientation.lock() {
        Ok(orientation) => orientation,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "orientation client lock poisoned".into()
            ));
        }
    };
    match run_sync_local(orientation.rotate(direction)) {
        Ok(_) => null_mut(),
        Err(error) => ffi_err!(error),
    }
}

/// Presses a named hardware button: home, lock, volume-up, volume-down, mute or siri.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_press_button(
    handle: *mut RemoteControlClientHandle,
    button: u8,
) -> *mut IdeviceFfiError {
    if handle.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let (usage_page, usage_code, hold_ms) = match button {
        0 => (0x0C, 0x40, 80),
        1 => (0x0C, 0x30, 200),
        2 => (0x0C, 0xE9, 80),
        3 => (0x0C, 0xEA, 80),
        4 => (0x0C, 0xE2, 80),
        5 => (0x0C, 0xCF, 1200),
        _ => return ffi_err!(IdeviceError::FfiInvalidArg),
    };

    let handle = unsafe { &*handle };
    let mut client = match handle.buttons.lock() {
        Ok(client) => client,
        Err(_) => {
            return ffi_err!(IdeviceError::InternalError(
                "button client lock poisoned".into()
            ));
        }
    };
    let result = run_sync_local(async {
        client
            .send_button(usage_page, usage_code, ButtonState::Down)
            .await?;
        tokio::time::sleep(Duration::from_millis(hold_ms)).await;
        client
            .send_button(usage_page, usage_code, ButtonState::Up)
            .await
    });

    match result {
        Ok(()) => null_mut(),
        Err(error) => ffi_err!(error),
    }
}

/// Stops screen sharing and frees the remote-control clients.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_free(handle: *mut RemoteControlClientHandle) {
    if handle.is_null() {
        return;
    }

    let handle = unsafe { Box::from_raw(handle) };
    if let Ok(mut universal_hid) = handle.universal_hid.lock()
        && let Some(mut keyboard) = universal_hid.keyboard.take()
    {
        let _ = run_sync_local(universal_hid.client.remove_main_keyboard(&mut keyboard));
    }
    if let Ok(mut display) = handle.display.lock() {
        let _ = run_sync_local(display.stop_media_stream());
    }
}
