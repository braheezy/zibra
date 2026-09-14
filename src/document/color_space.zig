//! Allocation-free CSS color coordinates, conversions and sRGB gamut mapping.
//! The color parser owns syntax and missing components. This module receives
//! numerical coordinates; callers retain the original values for CSSOM.
const std = @import("std");
const tokens = @import("css_tokenizer.zig");

pub const Space = enum {
    hsl,
    hwb,
    lab,
    lch,
    oklab,
    oklch,
    srgb,
    srgb_linear,
    display_p3,
    display_p3_linear,
    a98_rgb,
    prophoto_rgb,
    rec2020,
    xyz_d50,
    xyz_d65,

    pub fn name(self: Space) []const u8 {
        return switch (self) {
            .srgb_linear => "srgb-linear",
            .display_p3 => "display-p3",
            .display_p3_linear => "display-p3-linear",
            .a98_rgb => "a98-rgb",
            .prophoto_rgb => "prophoto-rgb",
            .xyz_d50 => "xyz-d50",
            .xyz_d65 => "xyz-d65",
            else => @tagName(self),
        };
    }

    pub fn predefined(self: Space) bool {
        return @intFromEnum(self) >= @intFromEnum(Space.srgb);
    }

    pub fn hueIndex(self: Space) ?usize {
        return switch (self) {
            .hsl, .hwb => 0,
            .lch, .oklch => 2,
            else => null,
        };
    }

    pub fn parse(encoded: []const u8) ?Space {
        if (tokens.identifierEquals(encoded, "xyz")) return .xyz_d65;
        inline for (std.meta.tags(Space)) |space| {
            if (tokens.identifierEquals(encoded, space.name())) return space;
        }
        return null;
    }

    /// Decodes a borrowed color() space identifier, including the XYZ alias.
    pub fn parsePredefined(encoded: []const u8) ?Space {
        if (tokens.identifierEquals(encoded, "xyz")) return .xyz_d65;
        inline for (std.meta.tags(Space)) |space| {
            if (space.predefined() and tokens.identifierEquals(encoded, space.name())) return space;
        }
        return null;
    }
};

pub const Vector = [3]f64;
/// Pointer-free, unpremultiplied coordinates. Missing channels remain distinct
/// from zero through interpolation; only the paint boundary substitutes zero.
pub const Coordinates = struct {
    space: Space,
    components: [4]?f64,

    pub fn values(self: Coordinates) Vector {
        return .{ self.components[0] orelse 0, self.components[1] orelse 0, self.components[2] orelse 0 };
    }
};
const Matrix = [3]Vector;

// CSS Color 4 conversion matrices and D50/D65 white adaptation:
// https://drafts.csswg.org/css-color-4/#color-conversion-code
const srgb_to_xyz: Matrix = .{
    .{ 506752.0 / 1228815.0, 87881.0 / 245763.0, 12673.0 / 70218.0 },
    .{ 87098.0 / 409605.0, 175762.0 / 245763.0, 12673.0 / 175545.0 },
    .{ 7918.0 / 409605.0, 87881.0 / 737289.0, 1001167.0 / 1053270.0 },
};
const xyz_to_srgb: Matrix = .{
    .{ 12831.0 / 3959.0, -329.0 / 214.0, -1974.0 / 3959.0 },
    .{ -851781.0 / 878810.0, 1648619.0 / 878810.0, 36519.0 / 878810.0 },
    .{ 705.0 / 12673.0, -2585.0 / 12673.0, 705.0 / 667.0 },
};
const p3_to_xyz: Matrix = .{
    .{ 608311.0 / 1250200.0, 189793.0 / 714400.0, 198249.0 / 1000160.0 },
    .{ 35783.0 / 156275.0, 247089.0 / 357200.0, 198249.0 / 2500400.0 },
    .{ 0, 32229.0 / 714400.0, 5220557.0 / 5000800.0 },
};
const a98_to_xyz: Matrix = .{
    .{ 573536.0 / 994567.0, 263643.0 / 1420810.0, 187206.0 / 994567.0 },
    .{ 591459.0 / 1989134.0, 6239551.0 / 9945670.0, 374412.0 / 4972835.0 },
    .{ 53769.0 / 1989134.0, 351524.0 / 4972835.0, 4929758.0 / 4972835.0 },
};
const prophoto_to_xyz: Matrix = .{
    .{ 0.7977666449006423, 0.13518129740053308, 0.0313477341283922 },
    .{ 0.2880748288194013, 0.711835234241873, 0.00008993693872564 },
    .{ 0, 0, 0.8251046025104602 },
};
const rec2020_to_xyz: Matrix = .{
    .{ 63426534.0 / 99577255.0, 20160776.0 / 139408157.0, 47086771.0 / 278816314.0 },
    .{ 26158966.0 / 99577255.0, 472592308.0 / 697040785.0, 8267143.0 / 139408157.0 },
    .{ 0, 19567812.0 / 697040785.0, 295819943.0 / 278816314.0 },
};
const d50_to_d65: Matrix = .{
    .{ 0.955473421488075, -0.02309845494876471, 0.06325924320057072 },
    .{ -0.0283697093338637, 1.0099953980813041, 0.021041441191917323 },
    .{ 0.012314014864481998, -0.020507649298898964, 1.330365926242124 },
};
const xyz_to_lms: Matrix = .{
    .{ 0.819022437996703, 0.3619062600528904, -0.1288737815209879 },
    .{ 0.0329836539323885, 0.9292868615863434, 0.0361446663506424 },
    .{ 0.0481771893596242, 0.2642395317527308, 0.6335478284694309 },
};
const lms_to_oklab: Matrix = .{
    .{ 0.210454268309314, 0.7936177747023054, -0.0040720430116193 },
    .{ 1.9779985324311684, -2.4285922420485799, 0.450593709617411 },
    .{ 0.0259040424655478, 0.7827717124575296, -0.8086757549230774 },
};
const oklab_to_lms: Matrix = .{
    .{ 1, 0.3963377773761749, 0.2158037573099136 },
    .{ 1, -0.1055613458156586, -0.0638541728258133 },
    .{ 1, -0.0894841775298119, -1.2914855480194092 },
};
const lms_to_xyz: Matrix = .{
    .{ 1.2268798758459243, -0.5578149944602171, 0.2813910456659647 },
    .{ -0.0405757452148008, 1.112286803280317, -0.0717110580655164 },
    .{ -0.0763729366746601, -0.4214933324022432, 1.5869240198367816 },
};

fn multiply(matrix: Matrix, vector: Vector) Vector {
    var result: Vector = undefined;
    for (matrix, 0..) |row, i| result[i] = row[0] * vector[0] + row[1] * vector[1] + row[2] * vector[2];
    return result;
}

fn inverse(comptime m: Matrix) Matrix {
    const a = m[0];
    const b = m[1];
    const c = m[2];
    const determinant = a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0]);
    return .{
        .{ (b[1] * c[2] - b[2] * c[1]) / determinant, (a[2] * c[1] - a[1] * c[2]) / determinant, (a[1] * b[2] - a[2] * b[1]) / determinant },
        .{ (b[2] * c[0] - b[0] * c[2]) / determinant, (a[0] * c[2] - a[2] * c[0]) / determinant, (a[2] * b[0] - a[0] * b[2]) / determinant },
        .{ (b[0] * c[1] - b[1] * c[0]) / determinant, (a[1] * c[0] - a[0] * c[1]) / determinant, (a[0] * b[1] - a[1] * b[0]) / determinant },
    };
}

fn signedPower(value: f64, power: f64) f64 {
    return std.math.copysign(std.math.pow(f64, @abs(value), power), value);
}

fn decode(space: Space, rgb: Vector) Vector {
    var result: Vector = undefined;
    for (rgb, 0..) |value, i| result[i] = switch (space) {
        .srgb, .display_p3 => if (@abs(value) <= 0.04045) value / 12.92 else std.math.copysign(std.math.pow(f64, (@abs(value) + 0.055) / 1.055, 2.4), value),
        .a98_rgb => signedPower(value, 563.0 / 256.0),
        .prophoto_rgb => if (@abs(value) <= 16.0 / 512.0) value / 16 else signedPower(value, 1.8),
        // CSS uses the display-referred BT.1886 transfer, not the camera OETF.
        .rec2020 => signedPower(value, 2.4),
        else => value,
    };
    return result;
}

fn encodeSrgb(linear: Vector) Vector {
    var result: Vector = undefined;
    for (linear, 0..) |value, i| result[i] = if (@abs(value) <= 0.0031308) 12.92 * value else std.math.copysign(1.055 * std.math.pow(f64, @abs(value), 1.0 / 2.4) - 0.055, value);
    return result;
}

fn encode(space: Space, linear: Vector) Vector {
    if (space == .srgb or space == .display_p3) return encodeSrgb(linear);
    var result: Vector = undefined;
    for (linear, 0..) |value, i| result[i] = switch (space) {
        .a98_rgb => signedPower(value, 256.0 / 563.0),
        .prophoto_rgb => if (@abs(value) <= 1.0 / 512.0) value * 16 else signedPower(value, 1.0 / 1.8),
        .rec2020 => signedPower(value, 1.0 / 2.4),
        else => value,
    };
    return result;
}

fn xyzToLab(d65: Vector) Vector {
    var xyz = multiply(inverse(d50_to_d65), d65);
    const white = Vector{ 0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585 };
    for (&xyz, white) |*channel, basis| {
        const value = channel.* / basis;
        channel.* = if (value > 216.0 / 24389.0) std.math.cbrt(value) else ((24389.0 / 27.0) * value + 16) / 116;
    }
    return .{ 116 * xyz[1] - 16, 500 * (xyz[0] - xyz[1]), 200 * (xyz[1] - xyz[2]) };
}

fn labToPolar(lab: Vector) Vector {
    return .{ lab[0], @sqrt(lab[1] * lab[1] + lab[2] * lab[2]), @mod(std.math.atan2(lab[2], lab[1]) * 180 / std.math.pi, 360) };
}

/// Convert extended sRGB without clipping or quantization. Powerless and
/// analogous missing components are handled by the interpolation owner.
pub fn fromSrgb(space: Space, rgb: Vector) Vector {
    if (space == .srgb) return rgb;
    if (space == .hsl or space == .hwb) {
        const maximum = @max(rgb[0], @max(rgb[1], rgb[2]));
        const minimum = @min(rgb[0], @min(rgb[1], rgb[2]));
        const delta = maximum - minimum;
        var hue: f64 = if (delta == 0) 0 else 60 * (if (maximum == rgb[0]) (rgb[1] - rgb[2]) / delta else if (maximum == rgb[1]) (rgb[2] - rgb[0]) / delta + 2 else (rgb[0] - rgb[1]) / delta + 4);
        if (space == .hwb) return .{ @mod(hue, 360), minimum * 100, (1 - maximum) * 100 };
        const lightness = (maximum + minimum) / 2;
        var saturation = if (delta == 0 or lightness == 0 or lightness == 1) 0 else (maximum - lightness) / @min(lightness, 1 - lightness);
        if (saturation < 0) {
            saturation = -saturation;
            hue += 180;
        }
        return .{ @mod(hue, 360), saturation * 100, lightness * 100 };
    }
    const linear = decode(.srgb, rgb);
    const xyz = multiply(srgb_to_xyz, linear);
    return switch (space) {
        .hsl, .hwb, .srgb => unreachable,
        .srgb_linear => linear,
        .display_p3, .display_p3_linear => encode(space, multiply(inverse(p3_to_xyz), xyz)),
        .a98_rgb => encode(space, multiply(inverse(a98_to_xyz), xyz)),
        .prophoto_rgb => encode(space, multiply(inverse(prophoto_to_xyz), multiply(inverse(d50_to_d65), xyz))),
        .rec2020 => encode(space, multiply(inverse(rec2020_to_xyz), xyz)),
        .xyz_d50 => multiply(inverse(d50_to_d65), xyz),
        .xyz_d65 => xyz,
        .lab => xyzToLab(xyz),
        .lch => labToPolar(xyzToLab(xyz)),
        .oklab => xyzToOklab(xyz),
        .oklch => labToPolar(xyzToOklab(xyz)),
    };
}

fn polarToLab(value: Vector) Vector {
    const angle = value[2] * std.math.pi / 180;
    return .{ value[0], value[1] * @cos(angle), value[1] * @sin(angle) };
}

fn labToXyz(lab: Vector) Vector {
    const y = (lab[0] + 16) / 116;
    var xyz = Vector{ y + lab[1] / 500, y, y - lab[2] / 200 };
    const white = Vector{ 0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585 };
    for (&xyz, white) |*value, basis| {
        const cube = value.* * value.* * value.*;
        value.* = basis * (if (cube > 216.0 / 24389.0) cube else (116 * value.* - 16) / (24389.0 / 27.0));
    }
    return multiply(d50_to_d65, xyz);
}

fn oklabToXyz(lab: Vector) Vector {
    var lms = multiply(oklab_to_lms, lab);
    for (&lms) |*value| value.* = value.* * value.* * value.*;
    return multiply(lms_to_xyz, lms);
}

fn xyzToOklab(xyz: Vector) Vector {
    var lms = multiply(xyz_to_lms, xyz);
    for (&lms) |*value| value.* = std.math.cbrt(value.*);
    return multiply(lms_to_oklab, lms);
}

/// Convert coordinates without gamut mapping. Missing components must have
/// been replaced by zero; Lab/LCH lightness and chroma must be range-checked.
/// Extended RGB coordinates remain unclipped through all transfer functions.
pub fn toSrgb(space: Space, values: Vector) Vector {
    if (space == .hsl or space == .hwb) {
        const saturation = if (space == .hsl) values[1] / 100 else 1;
        const lightness = if (space == .hsl) values[2] / 100 else 0.5;
        const amplitude = saturation * @min(lightness, 1 - lightness);
        var rgb: Vector = undefined;
        for (Vector{ 0, 8, 4 }, 0..) |n, i| {
            const k = @mod(n + values[0] / 30, 12);
            rgb[i] = lightness - amplitude * @max(-1, @min(@min(k - 3, 9 - k), 1));
        }
        if (space == .hwb) {
            const white = values[1];
            const black = values[2];
            // Work in percentages until the last division so exact half-byte
            // channels such as hwb(120 30% 50%) round upward when quantized.
            for (&rgb) |*value| value.* = if (white + black >= 100) white / (white + black) else (value.* * (100 - white - black) + white) / 100;
        }
        return rgb;
    }
    if (space == .srgb) return values;
    const xyz = switch (space) {
        .hsl, .hwb, .srgb => unreachable,
        .srgb_linear => return encodeSrgb(values),
        .display_p3, .display_p3_linear => multiply(p3_to_xyz, decode(space, values)),
        .a98_rgb => multiply(a98_to_xyz, decode(space, values)),
        .prophoto_rgb => multiply(d50_to_d65, multiply(prophoto_to_xyz, decode(space, values))),
        .rec2020 => multiply(rec2020_to_xyz, decode(space, values)),
        .xyz_d50 => multiply(d50_to_d65, values),
        .xyz_d65 => values,
        .lab => labToXyz(values),
        .lch => labToXyz(polarToLab(values)),
        .oklab => oklabToXyz(values),
        .oklch => oklabToXyz(polarToLab(values)),
    };
    return encodeSrgb(multiply(xyz_to_srgb, xyz));
}

fn clip(rgb: Vector) Vector {
    var result: Vector = undefined;
    for (rgb, 0..) |value, i| result[i] = if (std.math.isNan(value)) 0 else std.math.clamp(value, 0, 1);
    return result;
}

fn inGamut(rgb: Vector) bool {
    for (rgb) |value| if (!std.math.isFinite(value) or value < -0.0000001 or value > 1.0000001) return false;
    return true;
}

fn difference(lab: Vector, rgb: Vector) f64 {
    const other = xyzToOklab(multiply(srgb_to_xyz, decode(.srgb, rgb)));
    var squared: f64 = 0;
    for (lab, other) |a, b| squared += (a - b) * (a - b);
    return @sqrt(squared);
}

/// Project a numerical color into finite 0..1 sRGB for the native framebuffer.
/// Uses CSS Color 4 binary search with local MINDE, bounded to 64 iterations.
/// Unrepresentable/non-finite transforms fall back to channel clipping; the
/// original CSS coordinates remain available to the parser/serializer.
pub fn toPaint(space: Space, values: Vector) Vector {
    if (space == .lab or space == .lch or space == .oklab or space == .oklch) {
        if (values[0] <= 0) return .{ 0, 0, 0 };
        if (values[0] >= (if (space == .lab or space == .lch) @as(f64, 100) else 1)) return .{ 1, 1, 1 };
    }
    const rgb = toSrgb(space, values);
    if (inGamut(rgb)) return clip(rgb);
    const origin = xyzToOklab(multiply(srgb_to_xyz, decode(.srgb, rgb)));
    for (origin) |value| if (!std.math.isFinite(value)) return clip(rgb);
    if (origin[0] >= 1) return .{ 1, 1, 1 };
    if (origin[0] <= 0) return .{ 0, 0, 0 };
    var clipped = clip(rgb);
    if (difference(origin, clipped) < 0.02) return clipped;
    const chroma = @sqrt(origin[1] * origin[1] + origin[2] * origin[2]);
    if (!std.math.isFinite(chroma) or chroma == 0) return clipped;
    var low: f64 = 0;
    var high = chroma;
    var low_in_gamut = true;
    for (0..64) |_| {
        if (high - low <= 0.0001) break;
        const mid = (low + high) / 2;
        const current = Vector{ origin[0], origin[1] * mid / chroma, origin[2] * mid / chroma };
        const candidate = toSrgb(.oklab, current);
        if (low_in_gamut and inGamut(candidate)) {
            low = mid;
            continue;
        }
        clipped = clip(candidate);
        const delta = difference(current, clipped);
        if (delta < 0.02) {
            if (0.02 - delta < 0.0001) return clipped;
            low_in_gamut = false;
            low = mid;
        } else high = mid;
    }
    return clipped;
}

test "modern color space conversions preserve white neutral axes and reference colors" {
    for ([_]Space{ .srgb, .srgb_linear, .display_p3, .display_p3_linear, .a98_rgb, .prophoto_rgb, .rec2020 }) |space| {
        for (toSrgb(space, .{ 1, 1, 1 })) |value| try std.testing.expectApproxEqAbs(@as(f64, 1), value, 0.000001);
        try std.testing.expectEqual(Vector{ 0, 0, 0 }, toPaint(space, .{ 0, 0, 0 }));
    }
    const cases = [_]struct { space: Space, value: Vector, rgb: Vector }{
        .{ .space = .lab, .value = .{ 50, 50, 0 }, .rgb = .{ 0.756208, 0.304487, 0.475634 } },
        .{ .space = .oklab, .value = .{ 0.5, 0.05, 0 }, .rgb = .{ 0.48477, 0.34290, 0.38412 } },
        .{ .space = .oklch, .value = .{ 0.5, 0.2, 0 }, .rgb = .{ 0.70492, 0.02351, 0.37073 } },
        // With BT.1886 display transfer, neutral 0.5 encodes as 0.4725 in sRGB.
        .{ .space = .rec2020, .value = .{ 0.5, 0.5, 0.5 }, .rgb = .{ 0.4725, 0.4725, 0.4725 } },
        .{ .space = .xyz_d50, .value = .{ 0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585 }, .rgb = .{ 1, 1, 1 } },
    };
    // The published examples round coordinates and predate the higher-precision
    // D50 adaptation matrix. Their RGB8 projection must remain unchanged.
    for (cases) |case| for (toSrgb(case.space, case.value), case.rgb) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "modern color gamut mapping is bounded and preserves in-gamut colors" {
    const value = Vector{ 0.2, 0.4, 0.6 };
    try std.testing.expectEqual(value, toPaint(.srgb, value));
    const mapped = toPaint(.display_p3, .{ 1, 0, 0 });
    try std.testing.expectEqual(@as(f64, 1), mapped[0]);
    try std.testing.expect(mapped[1] > 0 and mapped[2] > 0);
    const source = xyzToOklab(multiply(srgb_to_xyz, decode(.srgb, toSrgb(.display_p3, .{ 1, 0, 0 }))));
    const result = xyzToOklab(multiply(srgb_to_xyz, decode(.srgb, mapped)));
    try std.testing.expectApproxEqAbs(source[0], result[0], 0.02);
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64), 1e300 }) |extreme| {
        for ([_]Space{ .lab, .oklch, .display_p3, .prophoto_rgb }) |space| {
            for (toPaint(space, .{ 0.5, extreme, 40 })) |channel| try std.testing.expect(std.math.isFinite(channel) and channel >= 0 and channel <= 1);
        }
    }
}
