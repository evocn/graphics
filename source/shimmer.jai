SHIMMER_WARMUP_FRAMES     :: 120;
SHIMMER_TIME_STEP         :: 1.0 / 450.0;
SHIMMER_THRESHOLD         :: 8.0;
SHIMMER_HEATMAP_SCALE     :: 4.0;
SHIMMER_SNAPSHOT_INTERVAL :: 150;
SHIMMER_CAMERA_POSITION   :: Vector3.{0, 0.2, -0.4};

shimmer_camera_path :: (time: float) {
    camera.position = SHIMMER_CAMERA_POSITION;
    camera.yaw      = 1.2  * sin(time * 3.3);
    camera.pitch    = 0.25 * sin(time * 2.3);
}

shimmer_accumulate :: () {
    pixels := read_screenshot_pixels();
    if !pixels return;
    defer free(pixels);

    count := cast(s64) (screenshot.extent.width * screenshot.extent.height);
    if shimmer.pixel_count == 0 {
        shimmer.pixel_count = count;
        shimmer.width    = screenshot.extent.width;
        shimmer.height   = screenshot.extent.height;
        shimmer.residual = NewArray(count, float);
    }
    assert(count == shimmer.pixel_count, "The window changed size during the shimmer measurement.");

    luma := NewArray(count, float);
    for i : 0..count - 1  luma[i] = pixel_luma(pixels[i]);

    view_projection := previous_view_projection;
    if shimmer.frames_seen >= 1 {
        invertible, inverse_view_projection := inverse(view_projection);
        assert(invertible);
        warp := shimmer.view_projection * inverse_view_projection;

        width  := cast(s64) shimmer.width;
        height := cast(s64) shimmer.height;
        previous := shimmer.previous_luma;
        for y : 0..height - 1  for x : 0..width - 1 {
            i := y * width + x;
            shimmer.residual[i] = -1;

            ndc_x := (x + 0.5) / width  * 2 - 1;
            ndc_y := (y + 0.5) / height * 2 - 1;
            clip := warp * Vector4.{ndc_x, ndc_y, 0.5, 1};
            if clip.w <= 0 continue;

            previous_x := (clip.x / clip.w * 0.5 + 0.5) * width  - 0.5;
            previous_y := (clip.y / clip.w * 0.5 + 0.5) * height - 0.5;
            if previous_x < 0 || previous_y < 0 || previous_x > xx (width - 1) || previous_y > xx (height - 1) continue;

            x0 := min(cast(s64) previous_x, width - 2);
            y0 := min(cast(s64) previous_y, height - 2);
            fx := previous_x - x0;
            fy := previous_y - y0;
            top    := previous[y0 * width + x0]       * (1 - fx) + previous[y0 * width + x0 + 1]       * fx;
            bottom := previous[(y0 + 1) * width + x0] * (1 - fx) + previous[(y0 + 1) * width + x0 + 1] * fx;
            residual := abs(luma[i] - (top * (1 - fy) + bottom * fy));

            shimmer.residual[i] = residual;
            shimmer.total += residual;
            shimmer.measured += 1;
            if residual > SHIMMER_THRESHOLD  shimmer.above += 1;
            shimmer.histogram[clamp(cast(s64) (residual / HISTOGRAM_MAX * HISTOGRAM_BINS), 0, HISTOGRAM_BINS - 1)] += 1;
        }

        if shimmer.samples % SHIMMER_SNAPSHOT_INTERVAL == SHIMMER_SNAPSHOT_INTERVAL / 2  write_snapshot(pixels);
        shimmer.samples += 1;
    }

    array_free(shimmer.previous_luma);
    shimmer.previous_luma   = luma;
    shimmer.view_projection = view_projection;
    shimmer.frames_seen += 1;
}

shimmer_finish :: () {
    if shimmer.measured == 0 {
        log_error("No shimmer samples were collected.");
        return;
    }

    p99 : float;
    {
        target := cast(s64) (0.99 * cast(float64) shimmer.measured);
        running : s64;
        for shimmer.histogram {
            running += it;
            if running >= target {
                p99 = (it_index + 1) * HISTOGRAM_MAX / HISTOGRAM_BINS;
                break;
            }
        }
    }

    print("SHIMMER mean % p99 % above_threshold % percent over % frames, snapshots %\n",
        formatFloat(shimmer.total / shimmer.measured, trailing_width = 3),
        formatFloat(p99, trailing_width = 2),
        formatFloat(100.0 * shimmer.above / shimmer.measured, trailing_width = 3),
        shimmer.samples, shimmer.snapshot_stem);
}

#scope_file

HISTOGRAM_BINS :: 1024;
HISTOGRAM_MAX  :: 128.0;

shimmer : struct {
    pixel_count     : s64;
    width           : u32;
    height          : u32;
    residual        : [] float;
    previous_luma   : [] float;
    view_projection : Matrix4;
    samples         : int;
    frames_seen     : int;

    total     : float64;
    measured  : s64;
    above     : s64;
    histogram : [HISTOGRAM_BINS] s64;

    snapshot_stem  : string;
    snapshot_count : int;
}

pixel_luma :: (p: u32) -> float {
    return 0.2126 * cast(float) (p & 0xFF) + 0.7152 * cast(float) ((p >> 8) & 0xFF) + 0.0722 * cast(float) ((p >> 16) & 0xFF);
}

write_snapshot :: (pixels: *u32) {
    if !shimmer.snapshot_stem {
        path := timestamped_png_path("bin/shimmer");
        shimmer.snapshot_stem = copy_string(slice(path, 0, path.count - 4));
    }

    count := shimmer.pixel_count;
    image := cast(*u32) alloc(4 * count);
    defer free(image);

    for i : 0..count - 1 {
        background := 0.5 * pixel_luma(pixels[i]);
        residual := shimmer.residual[i];
        if residual < 0 {
            image[i] = 0xFF60_0060;
            continue;
        }
        heat := clamp(residual / SHIMMER_HEATMAP_SCALE, 0, 1);
        r := cast(u32) (background + (255 - background) * heat);
        g := cast(u32) (background + (220 - background) * heat * heat);
        b := cast(u32) (background * (1 - heat));
        image[i] = r | (g << 8) | (b << 16) | 0xFF00_0000;
    }

    path := tprint("%-%.png", shimmer.snapshot_stem, shimmer.snapshot_count);
    written := stbi_write_png(temp_c_string(path), xx shimmer.width, xx shimmer.height, 4, image, xx (4 * shimmer.width));
    assert(written != 0, "Unable to write shimmer snapshot %", path);
    shimmer.snapshot_count += 1;
}
