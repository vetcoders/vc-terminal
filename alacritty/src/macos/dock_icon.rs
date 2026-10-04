//! The static Dock mark follows system appearance independently of window themes.
use std::ffi::c_void;

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{AllocAnyThread, DefinedClass, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::{NSApplication, NSImage};
use objc2_foundation::{
    MainThreadMarker, NSArray, NSData, NSKeyValueObservingOptions, NSObject,
    NSObjectNSKeyValueObserverRegistration, NSObjectProtocol, NSString, ns_string,
};

const DARK: &[u8] = include_bytes!("../../../assets/icon/vc-terminal-icon-dark.png");
const LIGHT: &[u8] = include_bytes!("../../../assets/icon/vc-terminal-icon-light.png");
static CONTEXT: u8 = 0;

fn context() -> *mut c_void {
    std::ptr::addr_of!(CONTEXT).cast_mut().cast()
}

struct Images {
    dark: Retained<NSImage>,
    light: Retained<NSImage>,
}

define_class!(
    // SAFETY: NSObject has no subclassing requirements; RAII belongs to DockIcon,
    // not this Objective-C class. AppKit calls it on the application main thread.
    #[unsafe(super = NSObject)]
    #[thread_kind = MainThreadOnly]
    #[name = "VCTerminalDockAppearanceObserver"]
    #[ivars = Images]
    struct AppearanceObserver;

    unsafe impl NSObjectProtocol for AppearanceObserver {}

    impl AppearanceObserver {
        // SAFETY: This is the NSObject KVO callback's exact object/pointer ABI.
        #[unsafe(method(observeValueForKeyPath:ofObject:change:context:))]
        fn appearance_changed(
            &self,
            key_path: Option<&NSString>,
            _object: Option<&AnyObject>,
            _change: Option<&AnyObject>,
            received_context: *mut c_void,
        ) {
            if received_context == context()
                && key_path == Some(ns_string!("effectiveAppearance"))
            {
                self.update();
            }
        }
    }
);

impl AppearanceObserver {
    fn update(&self) {
        let app = NSApplication::sharedApplication(self.mtm());
        let names = NSArray::from_slice(&[
            ns_string!("NSAppearanceNameAqua"),
            ns_string!("NSAppearanceNameDarkAqua"),
        ]);
        let matching = app.effectiveAppearance().bestMatchFromAppearancesWithNames(&names);
        let image = if matching.as_deref() == Some(ns_string!("NSAppearanceNameDarkAqua")) {
            &self.ivars().dark
        } else {
            &self.ivars().light
        };
        // SAFETY: Both images are decoded, retained NSImages. No window/palette
        // or global appearance property is written here.
        unsafe { app.setApplicationIconImage(Some(image)) };
    }
}

/// Retain the observer for the event-loop lifetime; unregister before release.
pub struct DockIcon {
    app: Retained<NSApplication>,
    observer: Retained<AppearanceObserver>,
}

impl DockIcon {
    pub fn install() -> Option<Self> {
        let mtm = MainThreadMarker::new()?;
        let app = NSApplication::sharedApplication(mtm);
        // Older macOS and failed image decoding retain the bundle's ICNS.
        if !app.respondsToSelector(sel!(effectiveAppearance)) {
            return None;
        }
        let dark = NSImage::initWithData(NSImage::alloc(), &NSData::with_bytes(DARK))?;
        let light = NSImage::initWithData(NSImage::alloc(), &NSData::with_bytes(LIGHT))?;
        let observer = AppearanceObserver::alloc(mtm).set_ivars(Images { dark, light });
        // SAFETY: NSObject init preserves the initialized ivars and class.
        let observer: Retained<AppearanceObserver> = unsafe { msg_send![super(observer), init] };
        // SAFETY: The retained observer implements KVO's callback with a static
        // context. Initial applies the icon before the first window is shown.
        unsafe {
            app.addObserver_forKeyPath_options_context(
                &observer,
                ns_string!("effectiveAppearance"),
                NSKeyValueObservingOptions::Initial | NSKeyValueObservingOptions::New,
                context(),
            );
        }
        Some(Self { app, observer })
    }
}

impl Drop for DockIcon {
    fn drop(&mut self) {
        // SAFETY: Exactly this registration exists while both objects are live.
        unsafe {
            self.app.removeObserver_forKeyPath_context(
                &self.observer,
                ns_string!("effectiveAppearance"),
                context(),
            );
        }
    }
}
