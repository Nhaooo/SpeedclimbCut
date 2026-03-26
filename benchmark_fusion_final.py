import json
import os


REPO_ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_ROOT = os.path.dirname(REPO_ROOT)

VIDEOS = [
    {
        "label": "IMG",
        "detections": os.path.join(DATA_ROOT, "detections.json"),
        "start_target": 86.0,
        "top_target": 94.0,
    },
    {
        "label": "Movie",
        "detections": os.path.join(DATA_ROOT, "detections_movie.json"),
        "start_target": 77.0,
        "top_target": 87.0,
    },
]

with open(os.path.join(DATA_ROOT, "motion_curves_cache.json"), "r", encoding="utf-8") as handle:
    CURVES = json.load(handle)


def smooth(values, window):
    smoothed = []
    for index in range(len(values)):
        start_index = max(0, index - window + 1)
        current_slice = values[start_index : index + 1]
        smoothed.append(sum(current_slice) / len(current_slice))
    return smoothed


def dedupe(indices, minimum_gap):
    deduped = []
    for index in indices:
        if not deduped or index - deduped[-1] >= minimum_gap:
            deduped.append(index)
    return deduped


def motion_state_machine(times, values):
    if not values:
        return None, None

    state = "idle"
    start_time = None
    top_time = None
    up_count = 0
    stable_count = 0
    last_value = values[0]

    for time, value in zip(times, values):
        delta = value - last_value

        if state == "idle":
            if 0.05 < value < 0.30 and delta > 0.005:
                up_count += 1
                if up_count >= 5:
                    state = "climbing"
                    start_time = max(0.0, time - 0.5)
            elif delta <= 0:
                up_count = 0

        elif state == "climbing":
            if value > 0.60:
                state = "near_top"

        elif state == "near_top":
            if abs(delta) < 0.01 or delta < 0:
                stable_count += 1
                if stable_count >= 3:
                    top_time = time
                    return start_time, top_time
            else:
                stable_count = 0

        last_value = value

    return start_time, top_time


def motion_valley_peak(times, values):
    if len(values) <= 10:
        return None, None

    start_candidates = []
    for index in range(4, len(values) - 10):
        before = values[index - 4 : index + 1]
        after = values[index + 1 : index + 11]

        if (
            values[index] <= 0.08
            and (sum(before) / len(before)) <= 0.08
            and values[index] <= min(before)
            and (max(after) - values[index]) >= 0.16
        ):
            start_candidates.append(index)

    start_candidates = dedupe(start_candidates, 8)

    peak_candidates = []
    for index in range(1, len(values) - 7):
        tail = values[index : index + 7]
        fall = values[index] - min(tail)
        is_local_max = values[index] >= values[index - 1] and values[index] >= values[index + 1]

        if is_local_max and values[index] >= 0.50 and fall >= 0.08:
            peak_candidates.append(index)

    best_pair = None
    best_score = None

    for start_index in start_candidates:
        start_time = times[start_index]

        for peak_index in peak_candidates:
            if peak_index <= start_index:
                continue

            peak_time = times[peak_index]
            duration = peak_time - start_time
            if duration < 6.0 or duration > 11.0:
                continue

            score = (
                (values[peak_index] * 3.0)
                + ((values[peak_index] - values[start_index]) * 2.0)
                - (abs(duration - 9.0) * 0.45)
                - values[start_index]
            )

            if best_score is None or score > best_score:
                best_score = score
                best_pair = (start_index, peak_index)
            break

    if best_pair is None:
        return None, None

    return times[best_pair[0]], times[best_pair[1]]


def preferred_start(times, raw_values):
    start_series = smooth(raw_values, 8)
    baseline_start, baseline_top = motion_state_machine(times, start_series)
    valley_start, valley_top = motion_valley_peak(times, start_series)

    if baseline_start is not None and baseline_top is not None and 5.0 <= (baseline_top - baseline_start) <= 15.0:
        return baseline_start, "baseline"
    if valley_start is not None:
        return valley_start, "valley_peak"
    return baseline_start, "baseline_start_only"


def estimate_top_time(times, values, start_time):
    candidate_indices = [
        index for index, time in enumerate(times)
        if start_time + 6.0 <= time <= start_time + 11.0
    ]

    if not candidate_indices:
        return None

    window_values = [values[index] for index in candidate_indices]
    peak = max(window_values)
    if peak < 0.45:
        return None

    threshold = peak * 0.96
    high_indices = [index for index in candidate_indices if values[index] >= threshold]
    if not high_indices:
        return None

    plateau_end_index = high_indices[0]
    for index in high_indices[1:]:
        if index == plateau_end_index + 1:
            plateau_end_index = index
        else:
            break

    return times[plateau_end_index], peak


def extract_track_candidates(detections):
    tracks = []
    next_id = 1

    for frame in detections:
        current_time = frame["t"]
        boxes = [
            box for box in frame["boxes"]
            if 0.35 < ((box[0] + box[2]) / 2.0) / 1080.0 < 0.72
        ]
        used = [False] * len(boxes)

        for track in tracks:
            if track["dead"]:
                continue

            last_box = track["points"][-1][1]
            last_center_x = ((last_box[0] + last_box[2]) / 2.0) / 1080.0
            last_center_y = ((last_box[1] + last_box[3]) / 2.0) / 1920.0
            best_match = None

            for index, box in enumerate(boxes):
                if used[index]:
                    continue

                center_x = ((box[0] + box[2]) / 2.0) / 1080.0
                center_y = ((box[1] + box[3]) / 2.0) / 1920.0
                dx = abs(center_x - last_center_x)
                dy = last_center_y - center_y

                if dx < 0.08 and -0.08 < dy < 0.25:
                    score = dx + (abs(dy) * 0.4)
                    if best_match is None or score < best_match[0]:
                        best_match = (score, index, box)

            if best_match is not None:
                _, box_index, box = best_match
                used[box_index] = True
                track["points"].append((current_time, box))
                track["missed"] = 0
            else:
                track["missed"] += 1
                if track["missed"] > 6:
                    track["dead"] = True

        for index, box in enumerate(boxes):
            if used[index]:
                continue

            tracks.append({
                "id": next_id,
                "points": [(current_time, box)],
                "missed": 0,
                "dead": False,
            })
            next_id += 1

    return tracks


def run_case(video):
    label = video["label"]
    times = CURVES[label]["times"]
    raw_values = CURVES[label]["raw"]
    top_series = smooth(raw_values, 3)

    pref_start, pref_method = preferred_start(times, raw_values)

    with open(video["detections"], "r", encoding="utf-8") as handle:
        detections = json.load(handle)

    if pref_start is None:
        return {
            "label": label,
            "method": pref_method,
            "error": None,
            "start": None,
            "top": None,
        }

    tracks = extract_track_candidates([
        frame for frame in detections
        if pref_start - 1.0 <= frame["t"] <= pref_start + 8.0
    ])

    best_candidate = None
    best_score = None

    for track in tracks:
        if len(track["points"]) < 4:
            continue

        y_values = [1.0 - (box[1] / 1920.0) for _, box in track["points"]]
        gain = max(y_values) - min(y_values)
        if gain < 0.05:
            continue

        start_time = track["points"][0][0]
        top_result = estimate_top_time(times, top_series, start_time)
        if top_result is None:
            continue

        top_time, peak_motion = top_result
        score = (-abs(start_time - pref_start)) + (gain * 2.0) + min(len(track["points"]) / 20.0, 1.0)

        if best_score is None or score > best_score:
            best_score = score
            best_candidate = {
                "id": track["id"],
                "start": start_time,
                "top": top_time,
                "gain": gain,
                "peak_motion": peak_motion,
                "points": len(track["points"]),
            }

    if best_candidate is None:
        return {
            "label": label,
            "method": pref_method,
            "error": None,
            "start": None,
            "top": None,
        }

    error = abs(best_candidate["start"] - video["start_target"]) + abs(best_candidate["top"] - video["top_target"])

    return {
        "label": label,
        "method": pref_method,
        "error": error,
        "start": best_candidate["start"],
        "top": best_candidate["top"],
        "track_id": best_candidate["id"],
        "points": best_candidate["points"],
        "gain": best_candidate["gain"],
        "peak_motion": best_candidate["peak_motion"],
        "start_error": abs(best_candidate["start"] - video["start_target"]),
        "top_error": abs(best_candidate["top"] - video["top_target"]),
    }


def main():
    total_error = 0.0
    results = []

    for video in VIDEOS:
        result = run_case(video)
        results.append(result)
        if result["error"] is not None:
            total_error += result["error"]

    print("Fusion final benchmark")
    print(f"Combined error: {total_error:.3f}s")
    print()

    for result in results:
        print(
            f"{result['label']}: method={result['method']} "
            f"start={result['start']} top={result['top']} "
            f"start_error={result.get('start_error')} top_error={result.get('top_error')} "
            f"track={result.get('track_id')} points={result.get('points')}"
        )


if __name__ == "__main__":
    main()
