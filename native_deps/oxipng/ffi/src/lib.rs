//! C ABI facade over the oxipng Rust library for App-side FFI.
//!
//! Official oxipng only exposes a Rust API + CLI. This crate ships the stable
//! C header in `include/oxipng.h` and builds `liboxipng` for packaging under
//! NativeDeps `native-headers/` + runtime dylib/DLL.

use std::{
    alloc::{alloc, dealloc, Layout},
    ffi::{CStr, CString},
    os::raw::c_char,
    path::PathBuf,
    ptr,
    slice,
    sync::OnceLock,
    time::Duration,
};

use oxipng::{InFile, Options, OutFile, StripChunks};

const VERSION: &str = env!("CARGO_PKG_VERSION");

thread_local! {
    static LAST_ERROR: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
}

#[repr(C)]
pub struct OxipngOptionsV1 {
    pub struct_size: u32,
    pub abi_version: u32,
    pub level: i32,
    pub force: i32,
    pub strip_safe: i32,
    pub optimize_alpha: i32,
    pub timeout_ms: u32,
}

fn set_error(msg: impl AsRef<str>) {
    let text = msg.as_ref().replace('\0', "");
    let cstr = CString::new(text).unwrap_or_else(|_| CString::new("error").unwrap());
    LAST_ERROR.with(|slot| *slot.borrow_mut() = cstr);
}

fn clear_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = CString::new("").unwrap());
}

fn cstr_to_path(ptr: *const c_char, label: &str) -> Result<PathBuf, String> {
    if ptr.is_null() {
        return Err(format!("{label} is null"));
    }
    let s = unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| format!("{label} is not valid UTF-8"))?;
    if s.is_empty() {
        return Err(format!("{label} is empty"));
    }
    Ok(PathBuf::from(s))
}

fn read_field<T: Copy>(base: *const u8, offset: usize, len: usize) -> Option<T> {
    if offset + std::mem::size_of::<T>() > len {
        return None;
    }
    Some(unsafe { ptr::read_unaligned(base.add(offset) as *const T) })
}

fn options_from_v1(options: *const OxipngOptionsV1) -> Result<Options, String> {
    if options.is_null() {
        return Ok(Options::from_preset(2));
    }

    let size = unsafe { (*options).struct_size } as usize;
    if size < 8 {
        return Err("OxipngOptionsV1.struct_size is too small".into());
    }
    let base = options as *const u8;
    let abi = read_field::<u32>(base, 4, size).unwrap_or(1);
    if abi != 1 {
        return Err(format!("unsupported OxipngOptionsV1.abi_version: {abi}"));
    }

    let level = read_field::<i32>(base, 8, size).unwrap_or(2).clamp(0, 6) as u8;
    let mut opts = Options::from_preset(level);

    if let Some(force) = read_field::<i32>(base, 12, size) {
        opts.force = force != 0;
    }
    if let Some(strip_safe) = read_field::<i32>(base, 16, size) {
        if strip_safe != 0 {
            opts.strip = StripChunks::Safe;
        }
    }
    if let Some(optimize_alpha) = read_field::<i32>(base, 20, size) {
        opts.optimize_alpha = optimize_alpha != 0;
    }
    if let Some(timeout_ms) = read_field::<u32>(base, 24, size) {
        if timeout_ms > 0 {
            opts.timeout = Some(Duration::from_millis(u64::from(timeout_ms)));
        }
    }
    Ok(opts)
}

fn allocate_blob(bytes: Vec<u8>) -> Result<(*mut u8, usize), String> {
    let len = bytes.len();
    if len == 0 {
        return Ok((ptr::null_mut(), 0));
    }
    let layout = Layout::from_size_align(len, 1).map_err(|e| e.to_string())?;
    let ptr = unsafe { alloc(layout) };
    if ptr.is_null() {
        return Err("out of memory".into());
    }
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, len);
    }
    Ok((ptr, len))
}

#[no_mangle]
pub extern "C" fn oxipng_version() -> *const c_char {
    static VERSION_CSTR: OnceLock<CString> = OnceLock::new();
    VERSION_CSTR
        .get_or_init(|| CString::new(VERSION).expect("version"))
        .as_ptr()
}

#[no_mangle]
pub extern "C" fn oxipng_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

#[no_mangle]
pub extern "C" fn oxipng_optimize_file(
    input_path: *const c_char,
    output_path: *const c_char,
    options: *const OxipngOptionsV1,
) -> i32 {
    clear_error();
    let result = (|| -> Result<(), String> {
        let input = cstr_to_path(input_path, "input_path")?;
        let output = cstr_to_path(output_path, "output_path")?;
        let opts = options_from_v1(options)?;
        oxipng::optimize(
            &InFile::Path(input),
            &OutFile::Path {
                path: Some(output),
                preserve_attrs: false,
            },
            &opts,
        )
        .map_err(|e| e.to_string())
    })();

    match result {
        Ok(()) => 0,
        Err(msg) => {
            set_error(msg);
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn oxipng_optimize_memory(
    input: *const u8,
    input_len: usize,
    options: *const OxipngOptionsV1,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    clear_error();
    if out_bytes.is_null() || out_len.is_null() {
        set_error("out_bytes/out_len is null");
        return -1;
    }
    unsafe {
        *out_bytes = ptr::null_mut();
        *out_len = 0;
    }
    if input.is_null() || input_len == 0 {
        set_error("input is null or empty");
        return -1;
    }

    let result = (|| -> Result<(*mut u8, usize), String> {
        let data = unsafe { slice::from_raw_parts(input, input_len) };
        let opts = options_from_v1(options)?;
        let optimized = oxipng::optimize_from_memory(data, &opts).map_err(|e| e.to_string())?;
        allocate_blob(optimized)
    })();

    match result {
        Ok((ptr, len)) => {
            unsafe {
                *out_bytes = ptr;
                *out_len = len;
            }
            0
        }
        Err(msg) => {
            set_error(msg);
            -1
        }
    }
}

/// Frees a buffer returned by [oxipng_optimize_memory]. [len] must be the
/// matching `out_len` value; passing a different length is undefined behaviour.
#[no_mangle]
pub extern "C" fn oxipng_blob_free(bytes: *mut u8, len: usize) {
    if bytes.is_null() || len == 0 {
        return;
    }
    let Ok(layout) = Layout::from_size_align(len, 1) else {
        return;
    };
    unsafe {
        dealloc(bytes, layout);
    }
}
