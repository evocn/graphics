srgb :: (r: float, g: float, b: float, a: float = 1.0) -> Vector4 {
    linear :: (c: float) -> float {
        if c <= 0.04045  return c / 12.92;
        return pow((c + 0.055) / 1.055, 2.4);
    }
    return .{linear(r), linear(g), linear(b), a};
}
