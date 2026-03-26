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


def mean_motion(times, values, start, end):
    window_values = [
        value for time, value in zip(times, values)
        if start <= time < end
    ]
    if not window_values:
        return 0.0
    return sum(window_values) / len(window_values)


def extract_track_candidates(detections):
    tracks = []
    next_id = 1

    for frame in detections:
        current_time = frame["t"]
        boxes = [
            box for box in frame["boxes"]
            if 0.40 < ((box[0] + box[2]) / 2.0) / 1080.0 < 0.66
            and (((box[2] - box[0]) / 1080.0) * ((box[3] - box[1]) / 1920.0)) < 0.08
            and ((box[3] - box[1]) / 1920.0) < 0.35
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

                area = ((box[2] - box[0]) / 1080.0) * ((box[3] - box[1]) / 1920.0)
                last_area = ((last_box[2] - last_box[0]) / 1080.0) * ((last_box[3] - last_box[1]) / 1920.0)

                if dx < 0.10 and -0.08 < dy < 0.28 and abs(area - last_area) < 0.03:
                    score = dx + (abs(dy) * 0.5) + (abs(area - last_area) * 0.4)
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

    with open(video["detections"], "r", encoding="utf-8") as handle:
        detections = json.load(handle)
    tracks = extract_track_candidates(detections)

    best_candidate = None
    best_score = None

    for track in tracks:
        if len(track["points"]) < 3:
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
        start_height = y_values[0]
        peak_height = max(y_values)
        end_height = y_values[-1]
        descent = max(0.0, peak_height - end_height)
        x_values = [((box[0] + box[2]) / 2.0) / 1080.0 for _, box in track["points"]]
        x_span = max(x_values) - min(x_values)
        area_values = [
            ((box[2] - box[0]) / 1080.0) * ((box[3] - box[1]) / 1920.0)
            for _, box in track["points"]
        ]
        area_average = sum(area_values) / len(area_values)
        track_duration = track["points"][-1][0] - start_time
        run_duration = top_time - start_time
        pre_motion = mean_motion(times, raw_values, start_time - 2.0, start_time)
        post_motion = mean_motion(times, raw_values, start_time, start_time + 3.0)
        rise_motion = post_motion - pre_motion

        score = (
            (gain * 6.0)
            + (descent * 2.0)
            + min(len(track["points"]) / 20.0, 1.0)
            + (1.2 if 6.0 <= run_duration <= 11.0 else 0.0)
            + (0.8 if start_height <= 0.30 else 0.0)
            + (rise_motion * 5.0)
            - (pre_motion * 4.0)
            - (max(track_duration - 15.0, 0.0) * 0.06)
            - (x_span * 2.0)
            - (area_average * 6.0)
        )

        if best_score is None or score > best_score:
            best_score = score
            best_candidate = {
                "id": track["id"],
                "start": start_time,
                "top": top_time,
                "track_duration": track_duration,
                "gain": gain,
                "peak_motion": peak_motion,
                "points": len(track["points"]),
                "start_height": start_height,
                "pre_motion": pre_motion,
                "post_motion": post_motion,
                "rise_motion": rise_motion,
            }

    if best_candidate is None:
        return {
            "label": label,
            "method": "track_motion_global",
            "error": None,
            "start": None,
            "top": None,
        }

    error = abs(best_candidate["start"] - video["start_target"]) + abs(best_candidate["top"] - video["top_target"])

    return {
        "label": label,
        "method": "track_motion_global",
        "error": error,
        "start": best_candidate["start"],
        "top": best_candidate["top"],
        "track_id": best_candidate["id"],
        "points": best_candidate["points"],
        "gain": best_candidate["gain"],
        "peak_motion": best_candidate["peak_motion"],
        "track_duration": best_candidate["track_duration"],
        "start_height": best_candidate["start_height"],
        "pre_motion": best_candidate["pre_motion"],
        "post_motion": best_candidate["post_motion"],
        "rise_motion": best_candidate["rise_motion"],
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
