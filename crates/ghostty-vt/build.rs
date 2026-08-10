// Build script: panicking on failure is expected behavior.
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    reason = "build scripts panic on failure by design"
)]

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

struct ZigCacheDirs {
    global: PathBuf,
    local: PathBuf,
}

impl ZigCacheDirs {
    fn new(out_dir: &Path) -> Self {
        Self {
            global: out_dir.join("zig-cache-global"),
            local: out_dir.join("zig-cache-local"),
        }
    }

    fn create(&self) {
        fs::create_dir_all(&self.global).expect("failed to create Zig global cache");
        fs::create_dir_all(&self.local).expect("failed to create Zig local cache");
    }

    fn apply(&self, cmd: &mut Command) {
        cmd.env("ZIG_GLOBAL_CACHE_DIR", &self.global);
        cmd.env("ZIG_LOCAL_CACHE_DIR", &self.local);
    }
}

fn main() {
    let manifest_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").unwrap());

    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("include/ghostty_vt.h").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("zig/build.zig").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("zig/build.zig.zon").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("zig/lib.zig").display()
    );
    println!("cargo:rerun-if-env-changed=GHOSTTY_SOURCE_DIR");
    println!("cargo:rerun-if-env-changed=GHOSTTY_ZIG_SYSTEM_DIR");
    println!("cargo:rerun-if-env-changed=ZIG_LIBC");
    println!("cargo:rerun-if-env-changed=CARGO_CFG_RELOCATION_MODEL");

    let ghostty_src = ghostty_source_dir();

    let zig = find_zig();
    assert_zig_available(&zig);

    let out_dir = PathBuf::from(std::env::var_os("OUT_DIR").unwrap());
    let zig_dir = prepare_zig_build_dir(&manifest_dir, &out_dir, &ghostty_src);
    let prefix = out_dir.join("zig-out");
    let cache_dirs = ZigCacheDirs::new(&out_dir);
    cache_dirs.create();

    let mut cmd = Command::new(&zig);
    cmd.current_dir(&zig_dir)
        .arg("build")
        .arg("-Doptimize=ReleaseFast")
        .arg("--prefix")
        .arg(&prefix);
    if needs_position_independent_code() {
        cmd.arg("-Dpic=true");
    }
    cache_dirs.apply(&mut cmd);
    apply_ghostty_system_cache(&mut cmd);
    apply_zig_libc(&mut cmd);

    // On macOS, Zig's LLVM backend needs the SDK sysroot to find libSystem
    // and other system libraries. Set SDKROOT so Zig can locate them.
    if cfg!(target_os = "macos") {
        if std::env::var_os("SDKROOT").is_none() {
            if let Ok(output) = Command::new("xcrun").arg("--show-sdk-path").output() {
                if output.status.success() {
                    let sdk = String::from_utf8_lossy(&output.stdout).trim().to_owned();
                    cmd.env("SDKROOT", &sdk);
                }
            }
        }
    }

    // When cross-compiling for musl, tell Zig to target musl too so the
    // static library's libc references resolve against musl at link time.
    if std::env::var("CARGO_CFG_TARGET_ENV").is_ok_and(|env| env == "musl") {
        cmd.arg("-Dtarget=x86_64-linux-musl");
    }

    let status = cmd.status().expect("failed to invoke zig");
    assert!(status.success(), "zig build failed");

    // Archive the emitted object with the system `ar`: zig 0.16's own
    // archiver writes members Apple's ld rejects ("not 8-byte aligned").
    let lib_dir = prefix.join("lib");
    let status = Command::new("ar")
        .arg("rcs")
        .arg(lib_dir.join("libghostty_vt.a"))
        .arg(lib_dir.join("ghostty_vt.o"))
        .status()
        .expect("failed to invoke ar");
    assert!(status.success(), "ar failed");

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=ghostty_vt");
    println!("cargo:rustc-link-lib=c");
}

fn ghostty_source_dir() -> PathBuf {
    let source = std::env::var_os("GHOSTTY_SOURCE_DIR").unwrap_or_else(|| {
        panic!(
            "GHOSTTY_SOURCE_DIR is required to build ghostty-vt; Buck sets it from \
             //crates/vm/guest/console/terminal:ghostty-source"
        )
    });
    let source = PathBuf::from(source);
    assert!(
        source.exists(),
        "GHOSTTY_SOURCE_DIR points to a missing path: {}",
        source.display()
    );
    source
        .canonicalize()
        .expect("failed to canonicalize GHOSTTY_SOURCE_DIR")
}

fn prepare_zig_build_dir(manifest_dir: &Path, out_dir: &Path, ghostty_src: &Path) -> PathBuf {
    let zig_dir = out_dir.join("zig-build-input");
    if zig_dir.exists() {
        fs::remove_dir_all(&zig_dir).expect("failed to remove previous Zig build input directory");
    }
    fs::create_dir_all(&zig_dir).expect("failed to create Zig build input directory");

    symlink(
        &manifest_dir.join("zig/build.zig"),
        &zig_dir.join("build.zig"),
    );
    symlink(
        &manifest_dir.join("zig/build.zig.zon"),
        &zig_dir.join("build.zig.zon"),
    );
    symlink(&manifest_dir.join("zig/lib.zig"), &zig_dir.join("lib.zig"));
    symlink(ghostty_src, &zig_dir.join("ghostty_src"));

    let include_dir = out_dir.join("include");
    if include_dir.exists() {
        fs::remove_dir_all(&include_dir)
            .expect("failed to remove previous Zig include input directory");
    }
    fs::create_dir_all(&include_dir).expect("failed to create Zig include input directory");
    symlink(
        &manifest_dir.join("include/ghostty_vt.h"),
        &include_dir.join("ghostty_vt.h"),
    );

    zig_dir
}

#[cfg(unix)]
fn symlink(source: &Path, destination: &Path) {
    std::os::unix::fs::symlink(source, destination).unwrap_or_else(|error| {
        panic!(
            "failed to symlink {} to {}: {error}",
            source.display(),
            destination.display()
        )
    });
}

#[cfg(windows)]
fn symlink(source: &Path, destination: &Path) {
    if source.is_dir() {
        std::os::windows::fs::symlink_dir(source, destination)
    } else {
        std::os::windows::fs::symlink_file(source, destination)
    }
    .unwrap_or_else(|error| {
        panic!(
            "failed to symlink {} to {}: {error}",
            source.display(),
            destination.display()
        )
    });
}

fn find_zig() -> PathBuf {
    if let Some(path) = std::env::var_os("ZIG") {
        return PathBuf::from(path);
    }

    if Command::new("zig").arg("version").output().is_ok() {
        return PathBuf::from("zig");
    }

    panic!("zig not on PATH; set ZIG or add pkgs.zig to the build environment");
}

fn assert_zig_available(zig: &Path) {
    let zig_check = Command::new(zig).arg("version").output();
    assert!(
        zig_check.is_ok(),
        "`zig` is required; add pkgs.zig to flake.nix dev shell"
    );
}

fn apply_ghostty_system_cache(cmd: &mut Command) {
    let Some(system_dir) = std::env::var_os("GHOSTTY_ZIG_SYSTEM_DIR") else {
        return;
    };

    if system_dir.is_empty() {
        return;
    }

    cmd.arg("--system").arg(system_dir);
}

fn apply_zig_libc(cmd: &mut Command) {
    let Some(libc_file) = std::env::var_os("ZIG_LIBC") else {
        return;
    };

    if libc_file.is_empty() {
        return;
    }

    // Zig's build runner forwards libc metadata to compile steps only when
    // `zig build` receives `--libc`. Nix builds set ZIG_LIBC because the
    // sandbox has no system `/usr/include` for Zig to discover.
    cmd.arg("--libc").arg(libc_file);
}

fn needs_position_independent_code() -> bool {
    // Cargo sets CARGO_CFG_RELOCATION_MODEL from `-Crelocation-model=`, so
    // the relocation-model check is enough for Cargo builds. Musl builds
    // always go through `-static-pie` in the final link and need every
    // input object to be position-independent (without this fallback the
    // zig-built libghostty_vt_zcu.o triggers "R_X86_64_32 against .rodata
    // can not be used when making a PIE object" at link time).
    let rel_pic = matches!(
        std::env::var("CARGO_CFG_RELOCATION_MODEL").as_deref(),
        Ok("pic" | "pie")
    );
    let musl = std::env::var("CARGO_CFG_TARGET_ENV").is_ok_and(|env| env == "musl");
    rel_pic || musl
}
