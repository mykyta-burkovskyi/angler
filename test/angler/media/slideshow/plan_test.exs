defmodule Angler.Media.Slideshow.PlanTest do
  use ExUnit.Case, async: true

  alias Angler.Media.Slideshow.Plan

  describe "canvas/2" do
    for {dimensions, size, expected} <- [
          {[{1080, 1440}], :hd, {1080, 1440}},
          {[{1081, 1439}], :hd, {1080, 1440}},
          {[{1080, 1920}], :hd, {1080, 1920}},
          {[{301, 900}], :hd, {1080, 1920}},
          {[{1000, 1000}], :hd, {1080, 1080}},
          {[{4000, 600}], :hd, {1920, 1080}},
          # natgeo: 2048x1366 photos
          {List.duplicate({2048, 1366}, 4), :hd, {1620, 1080}},
          # hullcity: one landscape, one portrait image; the tie goes to the cover
          {[{1290, 824}, {1440, 2470}], :hd, {1620, 1080}},
          {[{1440, 2470}, {1290, 824}], :hd, {1080, 1920}},
          # itsevykins: 3:4 photos of slightly different sizes
          {[{2160, 2880}, {1686, 2249}, {1851, 2468}, {1080, 1440}, {1036, 1381}], :hd,
           {1080, 1440}},
          # the majority wins over the cover
          {[{1080, 1920}, {1080, 1440}, {1080, 1440}], :hd, {1080, 1440}},
          {[{1080, 1080}, {1920, 1080}, {1080, 1920}], :hd, {1080, 1080}},
          {[{1080, 1350}], :hd, {1080, 1350}},
          {[{2048, 1366}], :sd, {1080, 720}},
          {[{1080, 1920}, {1080, 1440}, {1080, 1440}], :sd, {720, 960}},
          {[], :hd, {1080, 1920}},
          {[], :sd, {720, 1280}}
        ] do
      test "#{inspect(dimensions)} (#{size}) -> #{inspect(expected)}" do
        assert Plan.canvas(unquote(dimensions), unquote(size)) == unquote(expected)
      end
    end

    test "every preset has even dimensions and the 720 presets mirror the 1080 ones" do
      for size <- [:hd, :sd], {w, h} <- Plan.presets(size), do: assert(rem(w, 2) + rem(h, 2) == 0)

      ratios = fn size -> Enum.map(Plan.presets(size), fn {w, h} -> Float.round(w / h, 2) end) end
      assert ratios.(:hd) == ratios.(:sd)
    end
  end

  describe "timeline/3" do
    # {images, sound seconds, duration, slot frames, image order, loop, fade}
    for {count, audio, duration, frames, order, loop, fade} <- [
          # one image: as long as the sound
          {1, 75.0, 75.0, [2250], [0], false, nil},
          {1, 200.0, 90.0, [2700], [0], false, 1.5},
          {1, 2.0, 3.0, [90], [0], true, 1.0},
          # no sound: 3 s per image
          {1, nil, 3.0, [90], [0], false, nil},
          {4, nil, 12.0, List.duplicate(90, 4), [0, 1, 2, 3], false, nil},
          {12, nil, 36.0, List.duplicate(90, 12), Enum.to_list(0..11), false, nil},
          {2, 0.05, 6.0, [90, 90], [0, 1], false, nil},
          # one pass is at least as long as the sound
          {10, 30.0, 30.0, List.duplicate(90, 10), Enum.to_list(0..9), false, nil},
          {6, 30.0, 30.0, List.duplicate(150, 6), Enum.to_list(0..5), false, nil},
          {3, 8.0, 9.0, [90, 90, 90], [0, 1, 2], true, 1.5},
          # sound longer than six seconds per image: cycle through the images
          {5, 120.0, 90.0, List.duplicate(180, 15), Enum.map(0..14, &rem(&1, 5)), false, 1.5},
          {3, 40.0, 40.0, [171, 172, 171, 172, 171, 172, 171], [0, 1, 2, 0, 1, 2, 0], false, nil},
          # natgeo: 4 images, 55.4 s of sound
          {4, 55.4, 55.4, [166, 166, 167, 166, 166, 166, 166, 167, 166, 166],
           [0, 1, 2, 3, 0, 1, 2, 3, 0, 1], false, nil},
          # hullcity: 2 images, 16.3265 s of sound (the video is whole frames)
          {2, 16.3265, 490 / 30, [163, 164, 163], [0, 1, 0], false, nil}
        ] do
      test "#{count} images, sound #{inspect(audio)}" do
        plan = Plan.timeline(unquote(count), unquote(audio))

        assert plan.duration == unquote(duration)
        assert Enum.map(plan.slots, &elem(&1, 1)) == unquote(frames)
        assert Enum.map(plan.slots, &elem(&1, 0)) == unquote(order)
        assert plan.audio_loop == unquote(loop)
        assert plan.audio_fade == unquote(fade)
        assert plan.fps == 30
      end
    end

    test "35 images show for 2.57 s each and fill 90 s" do
      for audio <- [nil, 8.0, 60.0, 104.0] do
        plan = Plan.timeline(35, audio)
        frames = Enum.map(plan.slots, &elem(&1, 1))

        assert plan.duration == 90.0
        assert Enum.sum(frames) == 2700
        assert Enum.uniq(frames) |> Enum.sort() == [77, 78]
        assert Enum.map(plan.slots, &elem(&1, 0)) == Enum.to_list(0..34)
        assert_in_delta 2700 / 35 / 30, 2.57, 0.01
      end

      assert %Plan{audio_loop: true, audio_fade: 1.5} = Plan.timeline(35, 8.0)
      assert %Plan{audio_loop: false, audio_fade: 1.5} = Plan.timeline(35, 104.0)
    end

    test "the sound only loops or fades when it does not end with the video" do
      assert %Plan{audio_loop: false, audio_fade: nil} = Plan.timeline(3, 18.03)
      assert %Plan{audio_loop: false, audio_fade: nil} = Plan.timeline(3, 17.0)
      assert %Plan{audio_loop: true, audio_fade: fade} = Plan.timeline(3, 7.0)
      assert fade == 1.5
      # a short video fades over a third of its length
      assert %Plan{duration: 3.0, audio_fade: 1.0} = Plan.timeline(1, 1.0)
    end

    test "a shorter maximum duration (the dashboard setting) caps the video" do
      # 35 images in 60 s: 1.71 s each, the 8 s sound looped
      plan = Plan.timeline(35, 8.0, 60)
      frames = Enum.map(plan.slots, &elem(&1, 1))
      assert plan.duration == 60.0
      assert Enum.sum(frames) == 1800
      assert Enum.uniq(frames) |> Enum.sort() == [51, 52]
      assert Enum.map(plan.slots, &elem(&1, 0)) == Enum.to_list(0..34)
      assert %Plan{audio_loop: true, audio_fade: 1.5} = plan

      # a long sound: 60 s in 10 slots of 6 s, faded out
      plan = Plan.timeline(5, 120.0, 60)
      assert plan.duration == 60.0
      assert Enum.map(plan.slots, &elem(&1, 1)) == List.duplicate(180, 10)
      assert %Plan{audio_loop: false, audio_fade: 1.5} = plan

      assert %Plan{duration: 60.0, slots: [{0, 1800}]} = Plan.timeline(1, 75.0, 60)
      assert %Plan{duration: 60.0} = Plan.timeline(35, nil, 60)
      assert %Plan{duration: 60.0} = Plan.timeline(5, 60.0, 60)

      # shorter videos, and limits above 90 s or missing, change nothing
      assert Plan.timeline(4, 55.4, 60) == Plan.timeline(4, 55.4)
      assert Plan.timeline(35, 104.0, 1_800) == Plan.timeline(35, 104.0)
      assert Plan.timeline(35, 104.0, nil) == Plan.timeline(35, 104.0)

      # never under 3 s
      assert %Plan{duration: 3.0, slots: [{0, 45}, {1, 45}]} = Plan.timeline(2, nil, 1)
    end

    test "every image shows when the sound outlasts six seconds per image" do
      # Instagram's clip of "Solace" (20 photos) against the whole 140.586 s song
      plan = Plan.timeline(20, 140.586)
      assert plan.duration == 90.0
      assert Enum.map(plan.slots, &elem(&1, 0)) == Enum.to_list(0..19)
      assert Enum.map(plan.slots, &elem(&1, 1)) == List.duplicate(135, 20)
      assert %Plan{audio_loop: false, audio_fade: 1.5} = plan

      plan = Plan.timeline(16, 120.0)
      assert plan.duration == 90.0
      assert Enum.map(plan.slots, &elem(&1, 0)) == Enum.to_list(0..15)

      # a 90 s clip with a maximum duration of 60 s: 12 slots of 5 s, not 10 of 6 s
      plan = Plan.timeline(12, 90.0, 60)
      assert plan.duration == 60.0
      assert Enum.map(plan.slots, &elem(&1, 0)) == Enum.to_list(0..11)
      assert Enum.map(plan.slots, &elem(&1, 1)) == List.duplicate(150, 12)
      assert %Plan{audio_loop: false, audio_fade: 1.5} = plan
    end

    test "a cut clip plays as it is, or loops when the images outlast it" do
      # the 90 s clip cut from the song (FLAC, measured by ffprobe)
      plan = Plan.timeline(20, 89.999977)
      assert plan.duration == 90.0
      assert Enum.map(plan.slots, &elem(&1, 1)) == List.duplicate(135, 20)
      assert %Plan{audio_loop: false, audio_fade: nil} = plan

      plan = Plan.timeline(20, 30.0)
      assert plan.duration == 60.0
      assert Enum.map(plan.slots, &elem(&1, 0)) == Enum.to_list(0..19)
      assert %Plan{audio_loop: true, audio_fade: 1.5} = plan
    end

    test "a clip measured a sample longer than six seconds per image plays in one pass" do
      # ffprobe measures a cut clip to within a sample (23 µs at 44.1 kHz) of its length
      for {count, audio} <- [{5, 30.000023}, {10, 60.000023}, {3, 18.000023}, {5, 29.999977}] do
        plan = Plan.timeline(count, audio)
        assert plan.duration == count * 6.0
        assert plan.slots == Enum.map(0..(count - 1), &{&1, 180})
        assert %Plan{audio_loop: false, audio_fade: nil} = plan
      end

      # longer than one pass: whole 6 s slots, not one more slot of each
      plan = Plan.timeline(5, 36.000023)
      assert plan.duration == 36.0
      assert plan.slots == Enum.map([0, 1, 2, 3, 4, 0], &{&1, 180})

      # half a frame and more is a longer sound
      assert %Plan{slots: [_, _, _, _, _, _]} = Plan.timeline(5, 30.02)
    end

    test "slot boundaries are whole frames that add up to the duration" do
      for count <- 1..35, audio <- [nil, 0.5, 7.3, 16.3265, 29.86, 55.4, 61.7, 89.99, 300.0] do
        plan = Plan.timeline(count, audio)
        frames = Enum.map(plan.slots, &elem(&1, 1))

        # at least 2.57 s (35 images in 90 s); several images show at most 6 s at a time
        longest = if count == 1, do: 2700, else: 180
        assert Enum.all?(frames, &(is_integer(&1) and &1 >= 77 and &1 <= longest))
        assert Enum.sum(frames) / 30 == plan.duration
        assert plan.duration >= 3.0 and plan.duration <= 90.0
        assert Enum.all?(plan.slots, fn {index, _frames} -> index in 0..(count - 1) end)
        # every image shows at least once
        assert plan.slots |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == count
      end
    end
  end

  describe "maxrate_kbps/4" do
    test "caps the bitrate so the file stays within 90% of the target" do
      assert Plan.maxrate_kbps(90.0, 50_000_000, true, 3000) == 3000
      assert Plan.maxrate_kbps(90.0, 20_000_000, true, 3000) == 1484
      assert Plan.maxrate_kbps(90.0, 20_000_000, false, 3000) == 1600
      assert Plan.maxrate_kbps(90.0, 2_000_000_000, true, 2000) == 2000
      assert Plan.maxrate_kbps(3.0, 1_000, true, 3000) == 500
      assert Plan.maxrate_kbps(0.2, 100_000, false, 3000) == 720
    end

    test "fits 90 s into the cloud Bot API limit at the ceiling" do
      bytes = (Plan.maxrate_kbps(90.0, 50_000_000, true, 3000) * 1000 + 128_000) * 90 / 8
      assert bytes < 45_000_000
    end
  end

  test "quality/1 has CRF 20 at 1080 and CRF 22 at 720" do
    assert Plan.quality(:hd) == %{crf: 20, max_kbps: 3000}
    assert Plan.quality(:sd) == %{crf: 22, max_kbps: 2000}
  end
end
