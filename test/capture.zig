//! The bindings for screen capture compile, their IIDs are the ones Windows uses, and they work:
//! GraphicsCaptureSession.IsSupported through its statics.

test "the capture types' IIDs" {
    const capture = winrt.Windows.Graphics.Capture;
    // as wcap (mmozeiko/wcap) declares them
    try expectGuid(win32.Guid.initString("79c3f95b-31f7-4ec2-a464-632ef5d30760"), capture.IGraphicsCaptureItem.IID.*);
    try expectGuid(win32.Guid.initString("589b103f-6bbc-5df5-a991-02e28b3b66d5"), capture.IDirect3D11CaptureFramePoolStatics2.IID.*);
    try expectGuid(win32.Guid.initString("2c39ae40-7d2e-5044-804e-8b6799d4cf9e"), capture.IGraphicsCaptureSession2.IID.*);
    try expectGuid(win32.Guid.initString("30d5a829-7fa4-4026-83bb-d75bae4ea99e"), winrt.Windows.Foundation.IClosable.IID.*);
    // generic instances, from their signatures
    const Handler = winrt.Windows.Foundation.TypedEventHandler;
    try expectGuid(win32.Guid.initString("51a947f7-79cf-5a3e-a3a5-1289cfa6dfe8"), Handler(capture.Direct3D11CaptureFramePool, win32.IInspectable).IID.*);
    try expectGuid(win32.Guid.initString("e9c610c0-a68c-5bd9-8021-8589346eeee2"), Handler(capture.GraphicsCaptureItem, win32.IInspectable).IID.*);
}

test "GraphicsCaptureSession.IsSupported" {
    const capture = winrt.Windows.Graphics.Capture;
    {
        const hr = win32.RoInitialize(.MULTITHREADED);
        if (hr.failed) return error.SkipZigTest;
    }
    defer win32.RoUninitialize();
    var name: ?win32.HSTRING = null;
    const class_name = win32.L(capture.GraphicsCaptureSession.winrt_name);
    try std.testing.expect(!win32.WindowsCreateString(class_name, class_name.len, &name).failed);
    defer _ = win32.WindowsDeleteString(name);
    var statics: *capture.IGraphicsCaptureSessionStatics = undefined;
    try std.testing.expect(!win32.RoGetActivationFactory(name, capture.IGraphicsCaptureSessionStatics.IID, @ptrCast(&statics)).failed);
    defer _ = statics.IUnknown.Release();
    var supported = false;
    try std.testing.expect(!statics.IsSupported(&supported).failed);
    // Windows 10 1903 and later, which this is
    try std.testing.expect(supported);
}

const std = @import("std");
const win32 = @import("win32").everything;
const winrt = @import("winrt");
const expectGuid = winrt.runtime.expectGuid;
