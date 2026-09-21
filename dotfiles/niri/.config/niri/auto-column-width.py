#!/usr/bin/env python3
"""Keep one-column workspaces full width and two-column workspaces balanced."""

import json
import subprocess
import sys
import time


def run_action(*args: str) -> None:
    subprocess.run(
        ["niri", "msg", "action", *args],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def column_position(window: dict) -> int | None:
    position = window.get("layout", {}).get("pos_in_scrolling_layout")
    if isinstance(position, list) and position:
        return position[0]
    return None


def workspace_columns(windows: dict[int, dict], workspace_id: int) -> set[int]:
    return {
        position
        for window in windows.values()
        if window.get("workspace_id") == workspace_id
        and not window.get("is_floating", False)
        and (position := column_position(window)) is not None
    }


def apply_layout(
    windows: dict[int, dict], workspace_id: int, last_counts: dict[int, int]
) -> None:
    columns = workspace_columns(windows, workspace_id)
    count = len(columns)
    previous_count = last_counts.get(workspace_id)
    last_counts[workspace_id] = count

    if previous_count == count:
        return

    if count == 1:
        run_action("expand-column-to-available-width")
    elif count == 2:
        focused_column = next(
            (
                column_position(window)
                for window in windows.values()
                if window.get("workspace_id") == workspace_id
                and window.get("is_focused")
            ),
            2,
        )
        run_action("focus-column-first")
        run_action("set-column-width", "49%")
        run_action("focus-column-last")
        run_action("set-column-width", "49%")
        run_action("focus-column-first" if focused_column == 1 else "focus-column-last")


def main() -> int:
    windows: dict[int, dict] = {}
    focused_workspace: int | None = None
    last_counts: dict[int, int] = {}

    try:
        stream = subprocess.Popen(
            ["niri", "msg", "--json", "event-stream"],
            stdout=subprocess.PIPE,
            text=True,
        )
    except OSError as error:
        print(
            f"auto-column-width: unable to start niri event stream: {error}",
            file=sys.stderr,
        )
        return 1

    assert stream.stdout is not None
    for line in stream.stdout:
        try:
            event = json.loads(line)
            name, payload = next(iter(event.items()))
        except (ValueError, StopIteration):
            continue

        if name == "WorkspacesChanged":
            focused_workspace = next(
                (
                    workspace["id"]
                    for workspace in payload["workspaces"]
                    if workspace.get("is_focused")
                ),
                focused_workspace,
            )
            if focused_workspace is not None:
                time.sleep(0.05)
                apply_layout(windows, focused_workspace, last_counts)
        elif name == "WorkspaceActivated" and payload.get("focused"):
            focused_workspace = payload["id"]
            time.sleep(0.05)
            apply_layout(windows, focused_workspace, last_counts)
        elif name == "WindowsChanged":
            windows = {window["id"]: window for window in payload["windows"]}
            if focused_workspace is not None:
                time.sleep(0.05)
                apply_layout(windows, focused_workspace, last_counts)
        elif name == "WindowOpenedOrChanged":
            window = payload["window"]
            old_workspace = windows.get(window["id"], {}).get("workspace_id")
            if window.get("is_focused"):
                for existing in windows.values():
                    existing["is_focused"] = False
            windows[window["id"]] = window
            if focused_workspace is not None and (
                old_workspace == focused_workspace
                or window.get("workspace_id") == focused_workspace
            ):
                time.sleep(0.05)
                apply_layout(windows, focused_workspace, last_counts)
        elif name == "WindowClosed":
            closed_window = windows.pop(payload["id"], None)
            if (
                focused_workspace is not None
                and closed_window
                and closed_window.get("workspace_id") == focused_workspace
            ):
                time.sleep(0.05)
                apply_layout(windows, focused_workspace, last_counts)
        elif name == "WindowFocusChanged":
            for window in windows.values():
                window["is_focused"] = window["id"] == payload.get("id")
        elif name == "WindowLayoutsChanged":
            for window_id, layout in payload["changes"]:
                if window_id in windows:
                    windows[window_id]["layout"] = layout
            if focused_workspace is not None:
                time.sleep(0.05)
                apply_layout(windows, focused_workspace, last_counts)

    return stream.wait()


if __name__ == "__main__":
    raise SystemExit(main())
