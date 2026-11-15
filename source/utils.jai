srgb :: (r: float, g: float, b: float, a: float = 1.0) -> Vector4 {
    linear :: (c: float) -> float {
        if c <= 0.04045  return c / 12.92;
        return pow((c + 0.055) / 1.055, 2.4);
    }
    return .{linear(r), linear(g), linear(b), a};
}

timestamped_png_path :: (directory: string) -> string {
    make_directory_if_it_does_not_exist(directory);

    time := to_calendar(current_time_consensus(), .LOCAL);
    return tprint("%/%-%-%_%-%-%.png", directory,
        time.year,
        formatInt(time.month_starting_at_0 + 1,       minimum_digits = 2),
        formatInt(time.day_of_month_starting_at_0 + 1, minimum_digits = 2),
        formatInt(time.hour,   minimum_digits = 2),
        formatInt(time.minute, minimum_digits = 2),
        formatInt(time.second, minimum_digits = 2));
}
