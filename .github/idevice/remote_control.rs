use std::{ptr::null_mut, time::Duration};

use idevice::{
    core_device::{
        build_screen_audio_offer, build_screen_video_offer, build_start_audio_parameters,
        build_start_video_parameters, ButtonState, CallInfoBlob, DisplayServiceClient, ImageFormat,
        IndigoHidClient, ScreenCaptureServiceClient, UniversalHidServiceClient,
    },
    tcp::handle::UdpSocketHandle,
    IdeviceError, ReadWrite, RsdService,
};
use uuid::Uuid;

use crate::{
    core_device_proxy::AdapterHandle, ffi_err, rsd::RsdHandshakeHandle, run_sync_local,
    IdeviceFfiError,
};

const CLIENT_SUPPORTED_FEATURES: u64 = 140;

/// Owns the CoreDevice clients needed to view and control one paired device.
pub struct RemoteControlClientHandle {
    screenshot: ScreenCaptureServiceClient<Box<dyn ReadWrite>>,
    touchscreen: UniversalHidServiceClient<Box<dyn ReadWrite>>,
    buttons: IndigoHidClient<Box<dyn ReadWrite>>,
    display: DisplayServiceClient<Box<dyn ReadWrite>>,
    _audio_udp: UdpSocketHandle,
    _video_udp: UdpSocketHandle,
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

/// Opens the screenshot, display-stream, touchscreen and hardware-button services.
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

        let screenshot = ScreenCaptureServiceClient::connect_rsd(adapter, handshake).await?;
        let media = start_screen_media_session(adapter, handshake).await?;
        let touchscreen = UniversalHidServiceClient::connect_rsd(adapter, handshake).await?;
        let buttons = IndigoHidClient::connect_rsd(adapter, handshake).await?;

        Ok(RemoteControlClientHandle {
            screenshot,
            touchscreen,
            buttons,
            display: media.display,
            _audio_udp: media.audio_udp,
            _video_udp: media.video_udp,
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

/// Captures a JPEG frame. Free the returned bytes with `idevice_data_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn remote_control_client_take_frame(
    handle: *mut RemoteControlClientHandle,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> *mut IdeviceFfiError {
    if handle.is_null() || out_data.is_null() || out_len.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    let client = unsafe { &mut (*handle).screenshot };
    match run_sync_local(client.take_screenshot(None, ImageFormat::Jpeg)) {
        Ok(frame) => {
            let mut frame = frame.into_boxed_slice();
            unsafe {
                *out_data = frame.as_mut_ptr();
                *out_len = frame.len();
            }
            std::mem::forget(frame);
            null_mut()
        }
        Err(error) => ffi_err!(error),
    }
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

    let client = unsafe { &mut (*handle).touchscreen };
    match run_sync_local(client.tap(x, y)) {
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

    let client = unsafe { &mut (*handle).touchscreen };
    let steps = ((duration_ms / 16).clamp(2, 60)) as u32;
    let delay_ms = (duration_ms / u64::from(steps)).max(1);
    match run_sync_local(client.drag(start_x, start_y, end_x, end_y, steps, delay_ms)) {
        Ok(()) => null_mut(),
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

    let client = unsafe { &mut (*handle).buttons };
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

    let mut handle = unsafe { Box::from_raw(handle) };
    let _ = run_sync_local(handle.display.stop_media_stream());
}
