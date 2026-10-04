//! Isolated native KVO/NSImage proof. Never changes system or terminal appearance.
#[cfg(target_os = "macos")]
#[path = "../src/macos/dock_icon.rs"]
mod dock_icon;

#[cfg(target_os = "macos")]
fn main() {
    use objc2_app_kit::{NSAppearance, NSApplication, NSApplicationActivationPolicy};
    use objc2_foundation::{MainThreadMarker, ns_string};

    let mtm = MainThreadMarker::new().expect("probe is a main-thread executable");
    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Prohibited);
    let original = app.appearance();
    let observer =
        dock_icon::DockIcon::install().expect("supported appearance API and valid images");
    let output = std::path::PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output).unwrap();
    for (step, (name, png)) in [
        (
            ns_string!("NSAppearanceNameAqua"),
            include_bytes!("../../assets/icon/vc-terminal-icon-light.png").as_slice(),
        ),
        (
            ns_string!("NSAppearanceNameDarkAqua"),
            include_bytes!("../../assets/icon/vc-terminal-icon-dark.png").as_slice(),
        ),
        (
            ns_string!("NSAppearanceNameAqua"),
            include_bytes!("../../assets/icon/vc-terminal-icon-light.png").as_slice(),
        ),
    ]
    .into_iter()
    .enumerate()
    {
        let appearance = NSAppearance::appearanceNamed(name).expect("standard AppKit appearance");
        app.setAppearance(Some(&appearance));
        let actual = app.applicationIconImage().expect("observer applied a Dock image");
        // AppKit may copy the image; compare the actual native decoded carriers.
        let actual = actual.TIFFRepresentation().unwrap();
        let actual_path = output.join(format!("actual-{step}.tiff"));
        let expected_path = output.join(format!("expected-{step}.png"));
        std::fs::write(&actual_path, actual.to_vec()).unwrap();
        std::fs::write(&expected_path, png).unwrap();
        let assets = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../assets/icon");
        let comparison = std::process::Command::new("swift")
            .arg(assets.join("render.swift"))
            .arg(&assets)
            .arg("--compare-native")
            .arg(&actual_path)
            .arg(&expected_path)
            .output()
            .expect("native pixel comparator");
        assert!(
            comparison.status.success(),
            "native pixels differ: {}",
            String::from_utf8_lossy(&comparison.stderr)
        );
        print!("{}", String::from_utf8_lossy(&comparison.stdout));
        if step == 0 {
            // Prove the comparator rejects the other appearance, rather than
            // merely accepting any rendered NSImage or a missing observer.
            let opposite = assets.join("vc-terminal-icon-dark.png");
            let rejection = std::process::Command::new("swift")
                .arg(assets.join("render.swift"))
                .arg(&assets)
                .arg("--compare-native")
                .arg(&actual_path)
                .arg(opposite)
                .output()
                .expect("native negative comparator");
            assert!(!rejection.status.success(), "wrong-appearance image accepted");
            println!("wrong-appearance image rejected");
        }
        println!("native Dock image switched: {name}");
    }
    drop(observer);
    let before = app.applicationIconImage().unwrap().TIFFRepresentation().unwrap().to_vec();
    app.setAppearance(
        NSAppearance::appearanceNamed(ns_string!("NSAppearanceNameDarkAqua")).as_deref(),
    );
    assert!(
        app.applicationIconImage().unwrap().TIFFRepresentation().unwrap().to_vec() == before,
        "observer must be unregistered before release"
    );
    app.setAppearance(original.as_deref());
    println!("RAII unregister passed; system appearance unchanged");
}

#[cfg(not(target_os = "macos"))]
fn main() {
    println!("native Dock probe requires macOS");
}
