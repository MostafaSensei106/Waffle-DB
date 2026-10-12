//! Link the NDK C++ standard library **statically** on Android.
//!
//! Background: the `cc` crate (used by `usearch`/`cxx`) links `libc++_shared`
//! by default on Android, but Flutter APKs do not bundle it for plugin native
//! libs, so the produced `.so` fails to `dlopen` on devices with
//! `library "libc++_shared.so" not found`. Even with `CXXSTDLIB=c++_static`,
//! one RTTI symbol (`typeinfo for std::exception`) stays undefined because it
//! is defined only in `libc++abi.a`, not in `libc++_static.a`.
//!
//! Pulling both archives by absolute path into the final link resolves every
//! C++ symbol at build time: no shared C++ runtime to bundle, no APK bloat,
//! no loader surprises.
//!
//! NDK discovery is cargokit-proof: besides the usual env vars it derives the
//! sysroot from the `CC_<target>` compiler cargokit always provides, so this
//! works under Gradle (which scrubs the user's shell env) with zero setup.
//!
//! This script is a no-op for every non-Android target (desktop builds and
//! `cargo check` on the host are unaffected). If no NDK is found it emits a
//! warning and does nothing, so other platforms never break.

use std::env;
use std::path::PathBuf;

fn main() {
    let target = env::var("TARGET").unwrap_or_default();
    if !target.contains("android") {
        return;
    }

    let Some(lib_dir) = find_android_lib_dir(&target) else {
        println!(
            "cargo:warning=waffle_db: no Android NDK sysroot found, \
             skipping static libc++ link (device dlopen may fail)"
        );
        return;
    };

    // libc++abi first: it defines exception/RTTI symbols (e.g. the typeinfo
    // for std::exception) that libc++_static.a only references.
    for lib in ["libc++abi.a", "libc++_static.a"] {
        let path = lib_dir.join(lib);
        if !path.exists() {
            println!(
                "cargo:warning=waffle_db: {} not found, skipping",
                path.display()
            );
            continue;
        }
        println!("cargo:rustc-link-arg={}", path.display());
    }

    println!("cargo:rerun-if-env-changed=ANDROID_NDK_ROOT");
    println!("cargo:rerun-if-env-changed=ANDROID_NDK_HOME");
    println!("cargo:rerun-if-env-changed=ANDROID_NDK");
    println!("cargo:rerun-if-env-changed=ANDROID_HOME");
}

/// Returns `<sysroot>/usr/lib/<triple>` for the current Android target.
fn find_android_lib_dir(target: &str) -> Option<PathBuf> {
    let triple_dir: &str = match target {
        t if t.starts_with("aarch64") => "aarch64-linux-android",
        t if t.starts_with("armv7") => "arm-linux-androideabi",
        t if t.starts_with("i686") => "i686-linux-android",
        t if t.starts_with("x86_64") => "x86_64-linux-android",
        t if t.starts_with("riscv64") => "riscv64-linux-android",
        _ => return None,
    };

    if let Some(ndk) = find_ndk_root() {
        let dir = ndk_sysroot_lib(&ndk, triple_dir);
        if dir.join("libc++_static.a").exists() {
            return Some(dir);
        }
    }

    let transformed = target.to_uppercase().replace(['-', '.'], "_");
    let raw_key = format!("CC_{target}");
    let mut candidates = vec![
        raw_key,
        format!("CC_{transformed}"),
        "TARGET_CC".to_string(),
        "CC".to_string(),
    ];
    for key in candidates.drain(..) {
        let Ok(cc) = env::var(&key) else {
            continue;
        };
        let cc_path = PathBuf::from(&cc);
        if !cc_path.exists() {
            continue;
        }
        if let Some(sysroot) = print_sysroot(&cc) {
            let dir = sysroot.join("usr/lib").join(triple_dir);
            if dir.join("libc++_static.a").exists() {
                return Some(dir);
            }
        }
        if let Some(parent) = cc_path.parent().and_then(|p| p.parent()) {
            let dir = parent.join("sysroot/usr/lib").join(triple_dir);
            if dir.join("libc++_static.a").exists() {
                return Some(dir);
            }
        }
    }
    None
}

/// `<ndk>/toolchains/llvm/prebuilt/<host>/sysroot/usr/lib/<triple>`.
fn ndk_sysroot_lib(ndk: &str, triple_dir: &str) -> PathBuf {
    let host = env::var("HOST").unwrap_or_default();
    let prebuilt = if host.contains("apple") {
        "darwin-x86_64"
    } else if host.contains("windows") {
        "windows-x86_64"
    } else {
        "linux-x86_64"
    };
    PathBuf::from(ndk)
        .join("toolchains/llvm/prebuilt")
        .join(prebuilt)
        .join("sysroot/usr/lib")
        .join(triple_dir)
}

/// `ANDROID_NDK_ROOT` > `ANDROID_NDK_HOME` > `ANDROID_NDK` > newest `$ANDROID_HOME/ndk/*`.
fn find_ndk_root() -> Option<String> {
    for var in ["ANDROID_NDK_ROOT", "ANDROID_NDK_HOME", "ANDROID_NDK"] {
        if let Ok(path) = env::var(var) {
            if !path.is_empty() {
                return Some(path);
            }
        }
    }
    let home = env::var("ANDROID_HOME")
        .or_else(|_| env::var("ANDROID_SDK_ROOT"))
        .ok()?;
    let mut candidates: Vec<PathBuf> = std::fs::read_dir(PathBuf::from(home).join("ndk"))
        .ok()?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.is_dir())
        .collect();
    candidates.sort();
    candidates.pop().map(|p| p.to_string_lossy().into_owned())
}

/// Runs `<cc> -print-sysroot`; never fails the build on error.
fn print_sysroot(cc: &str) -> Option<PathBuf> {
    let out = std::process::Command::new(cc)
        .arg("-print-sysroot")
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let path = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if path.is_empty() {
        return None;
    }
    Some(PathBuf::from(path))
}
