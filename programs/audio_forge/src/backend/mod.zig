//! Audio Backend Module
//!
//! Provides audio output backends for different Linux audio systems.

pub const alsa = @import("alsa.zig");

pub const AlsaBackend = alsa.AlsaBackend;
pub const AlsaConfig = alsa.Config;
pub const SampleFormat = alsa.SampleFormat;
pub const AudioCallback = alsa.AudioCallback;

pub const listAlsaDevices = alsa.listDevices;

// Future backends:
// pub const pipewire = @import("pipewire.zig");
// pub const jack = @import("jack.zig");
