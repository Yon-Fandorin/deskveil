"""Validate this host's native popover geometry and live update regressions."""
import json
from pathlib import Path
import re
import sys

# Every verdict below is an assertion. Refuse optimized execution explicitly so
# -O/PYTHONOPTIMIZE can never turn incomplete or invalid data into a PASS.
if not __debug__:
    raise SystemExit("Native audit checker requires assertions; run Python without -O or PYTHONOPTIMIZE")


def rect(value):
    values = tuple(map(float, re.findall(r"-?(?:\d+(?:\.\d*)?|\.\d+)", value)))
    assert len(values) == 4, value
    return values


def contained(inner, outer):
    x, y, width, height = inner
    ox, oy, ow, oh = outer
    return x >= ox and y >= oy and x + width <= ox + ow and y + height <= oy + oh


def same_scroll_position(before, after):
    old = tuple(map(float, re.findall(r"-?(?:\d+(?:\.\d*)?|\.\d+)", before)))
    new = tuple(map(float, re.findall(r"-?(?:\d+(?:\.\d*)?|\.\d+)", after)))
    assert len(old) == len(new) == 2, "Invalid native scroll position"
    # AppKit can align a focused row to a backing pixel when its height changes.
    # Permit one point of vertical alignment, while still rejecting reset/jumps.
    return abs(old[0] - new[0]) <= 0.01 and abs(old[1] - new[1]) <= 1


def validate_viewport(interaction, phase):
    if "visibleRect" not in interaction:
        return
    document = rect(interaction["documentBounds"])
    frame = rect(interaction["documentFrame"])
    visible = rect(interaction["visibleRect"])
    assert frame[:2] == (0, 0), f"Document moved with clip bounds during {phase}"
    assert visible[2] > 0 and visible[3] > 0, f"Empty viewport during {phase}"
    assert abs(document[2] - visible[2]) <= 0.5, f"Document wider than viewport during {phase}"
    assert contained(visible, document), f"Viewport escaped document during {phase}"
    rows = sorted((rect(value) for value in interaction["rowFrames"].values()), key=lambda value: value[1])
    assert rows and rows[0][1] <= 1, f"Blank space above first row during {phase}"
    for row in rows:
        assert row[2] > 0 and row[3] > 0 and contained(row, document), f"Invalid row geometry during {phase}"
    assert interaction.get("powerFrames"), f"Missing actual power-control geometry during {phase}"
    for name, value in interaction["powerFrames"].items():
        x, _, width, _ = rect(value)
        assert x >= visible[0] and x + width <= visible[0] + visible[2], f"Horizontally clipped {name} during {phase}"
    vy, vh = visible[1], visible[3]
    covered = sum(max(0, min(y + height, vy + vh) - max(y, vy)) for _, y, _, height in rows)
    assert covered / vh >= 0.90, f"Blank display viewport during {phase}: rows cover only {covered / vh:.0%}"
    assert any(y < vy + vh and y + height > vy for _, y, _, height in rows), f"No visible rows during {phase}"


def validate_native_rows(snapshot, phase):
    """Compare rendered AppKit rows and progress indicators with their input."""
    rows = snapshot["auditRows"]
    model = snapshot["auditModel"]
    assert len(rows) == len(model), f"Missing or duplicate native rows during {phase}"
    assert len({row["control"] for row in rows}) == len(rows), f"Aliased native controls during {phase}"
    assert [row["id"] for row in rows] == [display["id"] for display in model], f"Incorrect native display order during {phase}"
    for row, display in zip(rows, model):
        context = f"display {display['id']} during {phase}"
        assert row["identifier"] == f"display-power-{display['id']}", f"Stale native identifier for {context}"
        assert display["name"] in row["texts"] and display["name"] in row["label"], f"Stale native name for {context}"
        assert row["enabled"] == display["enabled"], f"Incorrect native power availability for {context}"
        assert contained(rect(row["powerFrame"]), rect(row["bounds"])), f"Clipped native power control for {context}"
        percent = display["percent"]
        presentation = snapshot["interaction"]["brightness"][f"display-brightness-{display['id']}"]
        assert presentation["target"] == percent, f"Incorrect animation target for {context}"
        assert len(row["levels"]) == 1, f"Missing reserved brightness track for {context}"
        if percent is None:
            assert row["levels"][0]["value"] in ("확인 불가", "Unavailable"), f"Unavailable brightness claims a measured value for {context}"
            assert presentation["presentation"] is None and presentation["text"] == "—" and not presentation["animating"], context
            assert any(any(hint in text for hint in ("밝기 확인 불가", "Brightness unavailable")) for text in row["texts"]), f"Missing unavailable-brightness hint for {context}"
        else:
            assert len(row["levels"]) == 1 and row["levels"][0]["value"] == f"{percent}%", f"Stale native brightness for {context}"
            assert presentation["text"] in row["texts"], f"Missing native brightness text for {context}"
            assert 0 <= presentation["presentation"] <= 100, f"Invalid animated brightness for {context}"
            assert abs(float(presentation["text"].removesuffix("%")) - presentation["presentation"]) <= 0.51, context
            if not presentation["animating"]:
                assert presentation["presentation"] == percent, f"Unfinished brightness transition for {context}"
            assert not any(any(hint in text for hint in ("밝기 확인 불가", "Brightness unavailable")) for text in row["texts"]), f"Stale unavailable-brightness hint for {context}"
        level = rect(row["levels"][0]["frame"])
        assert level[2] > 0 and level[3] > 0 and contained(level, rect(row["bounds"])), f"Clipped brightness bar for {context}"


samples = json.loads(Path(sys.argv[1]).read_text())
required = {"refresh", "countdown-start", "countdown-tick", "height-grow", "height-shrink",
            "many-displays", "scroll-seed", "value-refresh", "brightness-known", "brightness-unknown",
            "brightness-invalid", "hotplug-reorder", "display-id-reuse", "same-identity-new-id",
            "duplicate-identities", "duplicate-refresh", "identity-recovered", "reopen", "countdown-end",
            "identify-display", "identify-expired", "brightness-animation-start", "brightness-animation-end",
            "brightness-all-unavailable", "brightness-all-recovered", "single-display-pending", "single-display-off", "single-display-off-end", "outside-click", "update-waiting", "update-cancelled"}
assert required <= {sample.get("phase") for sample in samples}, "Incomplete native audit scenarios"
topology_changes = {"many-displays", "hotplug-reorder", "display-id-reuse", "duplicate-identities", "identity-recovered", "identify-display"}
footer_focus_phases = {"hotplug-reorder", "display-id-reuse", "duplicate-identities", "duplicate-refresh", "identity-recovered"}
brightness_phases = {"brightness-known", "brightness-unknown", "brightness-invalid"}
stable_brightness_phases = brightness_phases | {"brightness-animation-start", "brightness-animation-end",
    "brightness-all-unavailable", "brightness-all-recovered", "single-display-pending", "single-display-off", "single-display-off-end"}
action_counts = {"hotplug-reorder": 1, "display-id-reuse": 2, "same-identity-new-id": 1,
                 "duplicate-identities": 2, "duplicate-refresh": 2, "identity-recovered": 2}
for sample in samples:
    before, after = sample["before"], sample["after"]
    phase = sample["phase"]
    if phase == "refresh":
        assert before == after, "Refreshing shifted the native popover layout"
    assert after["shown"], "Audit must use an actual displayed NSPopover"
    if len(after["interaction"]["displayControls"]) > 3:
        assert "visibleRect" in after["interaction"], "Missing native viewport geometry; recapture this audit"
    validate_viewport(after["interaction"], phase)
    validate_native_rows(before, f"before {phase}")
    validate_native_rows(after, phase)
    if phase == "identify-display":
        check = sample["identifyCheck"]
        assert all(check.get(name) is True for name in ["staleIgnored", "rowActionOnly", "powerExcluded", "labelExcluded", "brightnessGestureDelivered", "shown", "focusPreserved"]), check
        marker = after["identification"]
        assert marker["visible"] and marker["ignoresMouse"] and not marker["key"] and not marker["canBecomeKey"], marker
    if phase == "identify-expired":
        assert not after["identification"]["visible"], "Display marker did not automatically dismiss"
    if phase in stable_brightness_phases:
        assert before["contentSize"] == after["contentSize"], f"Brightness update resized popover during {phase}"
        assert [rect(row["bounds"]) for row in before["auditRows"]] == [rect(row["bounds"]) for row in after["auditRows"]], f"Brightness update shifted row geometry during {phase}"
    if phase in {"brightness-animation-start", "brightness-animation-end"}:
        selected_id = after["auditModel"][0]["id"]
        key = f"display-brightness-{selected_id}"
        level = after["interaction"]["brightness"][key]
        assert level["target"] == 90, level
        if phase == "brightness-animation-start" and not sample["visualCheck"]["reduceMotion"]:
            assert level["animating"] and level["presentation"] < 90, level
        if phase == "brightness-animation-end":
            assert level["presentation"] == 90 and not level["animating"], level
            middle = sample["visualCheck"]["midpoint"][key]
            if not sample["visualCheck"]["reduceMotion"]:
                assert middle["animating"] and 55 < middle["presentation"] < 90, middle
    if phase in {"single-display-pending", "single-display-off", "single-display-off-end"}:
        changed_key = f"display-brightness-{after['auditModel'][0]['id']}"
        changed = after["interaction"]["brightness"][changed_key]
        if phase == "single-display-off":
            assert changed["target"] == 0, changed
            if not sample["visualCheck"].get("reduceMotion", False):
                assert changed["animating"] and changed["presentation"] > 0, "DDC-like unknown-to-measured Off skipped animation"
        if phase == "single-display-off-end":
            assert changed["presentation"] == 0 and not changed["animating"], changed
        for key, value in after["interaction"]["brightness"].items():
            if key != changed_key:
                assert value == before["interaction"]["brightness"][key], f"Toggling one screen disturbed {key}"
    if phase == "outside-click":
        assert all(sample["visualCheck"].get(key) is True for key in ("insidePreserved", "anchorPreserved", "monitorsInstalled", "outsideClosed", "monitorsRemoved", "reopened")), sample["visualCheck"]
    assert rect(after["contentFrame"]) == rect(after["safeFrame"]), "Content escaped its safe area"
    _, _, width, height = rect(after["contentFrame"])
    for name in ["dashboardFrame", "primaryFrame", "footerFrame"]:
        assert contained(rect(after[name]), (0, 0, width, height)), f"Clipped {name}"
    for name, frame in after["actionFrames"].items():
        assert contained(rect(frame), (0, 0, width, height)), f"Clipped {name} during {phase}"
    for name in before["actionControls"].keys() & after["actionControls"].keys():
        assert before["actionControls"][name] == after["actionControls"][name], f"Replaced {name} during {phase}"
    if phase not in topology_changes | {"same-identity-new-id"}:
        assert before["interaction"]["displayControls"] == after["interaction"]["displayControls"], f"Replaced display controls during {phase}"
    if phase in {"value-refresh", "reopen"} | brightness_phases:
        assert same_scroll_position(before["interaction"]["scrollOrigin"], after["interaction"]["scrollOrigin"]), f"Reset scroll during {phase}"
    if phase in {"countdown-tick", "value-refresh"} | brightness_phases | footer_focus_phases:
        assert sample["focusEstablished"], f"Could not establish native keyboard focus during {phase}"
        assert before["focusedControl"] == after["focusedControl"] != "", f"Lost keyboard focus during {phase}"
        assert before["focusedObject"] == after["focusedObject"] != "", f"Replaced focused native control during {phase}"
    if phase == "same-identity-new-id":
        assert sample["focusEstablished"], "Could not focus the native control before display ID changed"
        assert before["focusedControl"] == "display-power-9" and after["focusedControl"] == "display-power-19", "Focused control did not acquire the current display ID"
        assert before["focusedObject"] == after["focusedObject"] != "", "Display ID change replaced the focused native control"
        assert [row["control"] for row in before["auditRows"]] == [row["control"] for row in after["auditRows"]], "Display ID change rebuilt the native rows"
    if phase in {"brightness-known", "brightness-unknown"}:
        old_row = next(row for row in before["auditRows"] if row["id"] == 5)
        new_row = next(row for row in after["auditRows"] if row["id"] == 5)
        old_height, new_height = rect(old_row["bounds"])[3], rect(new_row["bounds"])[3]
        assert new_height == old_height, f"Brightness availability shifted row height during {phase}"
    if phase in {"duplicate-identities", "duplicate-refresh"}:
        for display_id in (5, 19):
            row = next(row for row in after["auditRows"] if row["id"] == display_id)
            assert not row["enabled"], f"Ambiguous display identity enabled native actions for {display_id}"
    checks = sample["actionChecks"]
    assert len(checks) == action_counts.get(phase, 0), f"Missing native target/action checks during {phase}"
    for check in checks:
        assert check["sent"], f"Native target/action was not dispatched during {phase}"
        assert check["observed"] == check["expected"], f"Stale or unavailable display action during {phase}: {check}"
    if phase in {"height-grow", "height-shrink", "countdown-start", "countdown-end", "update-waiting", "update-cancelled"}:
        old_height = rect(before["contentFrame"])[3]
        assert height != old_height, f"Expected height change during {phase}"
        assert (height > old_height) == (phase in {"height-grow", "countdown-start", "update-waiting"}), f"Incorrect height change during {phase}"
    if phase == "scroll-seed":
        assert after["interaction"]["scrollOrigin"] != "{0, 0}", "Scroll scenario did not move the document"
anchors = ", ".join(sorted({sample.get("anchor", "unspecified") for sample in samples}))
print(f"PASS: {len(samples)} native scenarios ({anchors}); stable brightness geometry, animated values, outside-click dismissal, topology/identity actions, focus and scrolling on this host")
