#!/usr/bin/python3
"""Omarchy OCR helper — stdlib only.

Subcommands:
  region | clip | screen | window
      Capture → optional 2x upscale → tesseract PSM 6 + 11 → keep
      the higher-confidence result. Copies text to the clipboard,
      appends history, prints JSON to stdout:
      {ok, text, chars, langs, error, ms}

  history list
  history delete <id>
  history copy <id>

Flags:
  --langs eng          comma or plus separated (eng,por → eng+por)
  --upscale / --no-upscale
  --geom 'x,y wxh'     skip slurp / hyprctl (tests + window override)
  --history-size 20
  --no-copy            skip wl-copy
  --no-history         skip history append
"""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "omarchy" / "ocr"
HISTORY_PATH = CACHE_DIR / "history.json"
STATUS_PATH = CACHE_DIR / "status.json"
PNG_SIG = b"\x89PNG\r\n\x1a\n"
DEFAULT_LANGS = "eng"
DEFAULT_HISTORY = 20
SMALL_EDGE = 600


def emit(payload: dict, exit_code: int = 0) -> int:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    return exit_code


def fail(error: str, langs: str = DEFAULT_LANGS, ms: int = 0) -> int:
    payload = {
        "ok": False,
        "text": "",
        "chars": 0,
        "langs": langs,
        "error": error,
        "ms": ms,
    }
    write_status(payload)
    return emit(payload, 1)


def which(name: str) -> str | None:
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(folder) / name
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def run(cmd: list[str], stdin: bytes | None = None, text: bool = False, timeout: float | None = 60):
    return subprocess.run(
        cmd,
        input=stdin,
        capture_output=True,
        text=text,
        timeout=timeout,
        check=False,
    )


def normalize_langs(raw: str) -> str:
    value = (raw or DEFAULT_LANGS).strip()
    if not value:
        value = DEFAULT_LANGS
    value = value.replace(",", "+")
    parts = [p.strip() for p in value.split("+") if p.strip()]
    cleaned = []
    for part in parts:
        if not part or part.startswith("-"):
            continue
        if not all(ch.isalnum() or ch in "-_" for ch in part):
            continue
        cleaned.append(part)
    return "+".join(cleaned) or DEFAULT_LANGS


def png_size(data: bytes) -> tuple[int, int] | None:
    if len(data) < 24 or data[:8] != PNG_SIG:
        return None
    width, height = struct.unpack(">II", data[16:24])
    if width <= 0 or height <= 0:
        return None
    return width, height


def ensure_png(data: bytes) -> bytes:
    if data[:8] == PNG_SIG:
        return data
    magick = which("magick")
    if not magick:
        return data
    proc = run([magick, "-", "png:-"], stdin=data)
    if proc.returncode == 0 and proc.stdout[:8] == PNG_SIG:
        return proc.stdout
    return data


def upscale_2x(data: bytes) -> tuple[bytes, str]:
    """Return (bytes, note). note is 'magick', 'ffmpeg', or 'skipped'."""
    magick = which("magick")
    if magick:
        proc = run([magick, "png:-", "-filter", "Lanczos", "-resize", "200%", "png:-"], stdin=data)
        if proc.returncode == 0 and proc.stdout[:8] == PNG_SIG:
            return proc.stdout, "magick"
    ffmpeg = which("ffmpeg")
    if ffmpeg:
        proc = run(
            [
                ffmpeg,
                "-hide_banner",
                "-loglevel",
                "error",
                "-i",
                "pipe:0",
                "-vf",
                "scale=iw*2:ih*2:flags=lanczos",
                "-f",
                "image2pipe",
                "-vcodec",
                "png",
                "pipe:1",
            ],
            stdin=data,
        )
        if proc.returncode == 0 and proc.stdout[:8] == PNG_SIG:
            return proc.stdout, "ffmpeg"
    return data, "skipped"


def maybe_upscale(data: bytes, enabled: bool) -> tuple[bytes, bool, str]:
    if not enabled:
        return data, False, "disabled"
    size = png_size(data)
    if size is None:
        return data, False, "unknown-size"
    width, height = size
    if min(width, height) >= SMALL_EDGE:
        return data, False, "large-enough"
    scaled, tool = upscale_2x(data)
    return scaled, tool != "skipped", tool


def parse_tsv(tsv: str) -> tuple[str, float, int]:
    """Return (text, mean_word_confidence, word_count)."""
    lines = tsv.splitlines()
    if not lines:
        return "", 0.0, 0
    header = lines[0].split("\t")
    try:
        level_i = header.index("level")
        line_i = header.index("line_num")
        conf_i = header.index("conf")
        text_i = header.index("text")
    except ValueError:
        # No header — tesseract sometimes still prints one; treat as empty.
        return "", 0.0, 0

    words: list[tuple[int, str, float]] = []
    for raw in lines[1:]:
        cols = raw.split("\t")
        if len(cols) <= max(level_i, line_i, conf_i, text_i):
            continue
        try:
            level = int(float(cols[level_i]))
        except ValueError:
            continue
        if level != 5:
            continue
        try:
            conf = float(cols[conf_i])
        except ValueError:
            continue
        if conf < 0:
            continue
        word = cols[text_i].strip()
        if not word:
            continue
        try:
            line_num = int(float(cols[line_i]))
        except ValueError:
            line_num = 0
        words.append((line_num, word, conf))

    if not words:
        return "", 0.0, 0

    parts: list[str] = []
    current_line = words[0][0]
    for line_num, word, _conf in words:
        if parts and line_num != current_line:
            parts.append("\n")
            current_line = line_num
        elif parts and parts[-1] != "\n":
            parts.append(" ")
        parts.append(word)

    text = "".join(parts).strip()
    mean = sum(c for _l, _w, c in words) / len(words)
    return text, mean, len(words)


def tesseract_psm(image: bytes, langs: str, psm: int) -> tuple[str, float, int, str]:
    binary = which("tesseract")
    if not binary:
        return "", 0.0, 0, "tesseract not found"
    proc = run(
        [binary, "stdin", "stdout", "-l", langs, "--psm", str(psm), "tsv"],
        stdin=image,
    )
    if proc.returncode != 0:
        err = (proc.stderr or b"").decode("utf-8", "replace").strip()
        return "", 0.0, 0, err or f"tesseract psm {psm} failed"
    text, mean, count = parse_tsv(proc.stdout.decode("utf-8", "replace"))
    return text, mean, count, ""


def pick_best(image: bytes, langs: str) -> tuple[str, float, int, str]:
    """Run PSM 6 and 11, keep the higher-confidence result."""
    best_text = ""
    best_conf = -1.0
    best_count = 0
    last_err = ""
    for psm in (6, 11):
        text, mean, count, err = tesseract_psm(image, langs, psm)
        if err:
            last_err = err
            continue
        score = mean
        # Prefer the result that actually produced words when confidences tie.
        if count > 0 and (score > best_conf or (score == best_conf and count > best_count)):
            best_text, best_conf, best_count = text, score, count
    if best_count == 0:
        return "", 0.0, 0, last_err
    return best_text, best_conf, best_count, ""


def capture_region(geom: str | None) -> tuple[bytes | None, str]:
    if not geom:
        slurp = which("slurp")
        if not slurp:
            return None, "slurp not found"
        proc = run([slurp], text=True)
        geom = (proc.stdout or "").strip()
        if proc.returncode != 0 or not geom:
            return None, "cancelled"
    return grim_geom(geom)


def grim_geom(geom: str) -> tuple[bytes | None, str]:
    grim = which("grim")
    if not grim:
        return None, "grim not found"
    proc = run([grim, "-g", geom, "-"])
    if proc.returncode != 0 or not proc.stdout:
        err = (proc.stderr or b"").decode("utf-8", "replace").strip()
        return None, err or "grim failed"
    return proc.stdout, ""


def capture_screen() -> tuple[bytes | None, str]:
    grim = which("grim")
    if not grim:
        return None, "grim not found"
    proc = run([grim, "-"])
    if proc.returncode != 0 or not proc.stdout:
        err = (proc.stderr or b"").decode("utf-8", "replace").strip()
        return None, err or "grim failed"
    return proc.stdout, ""


def capture_clip() -> tuple[bytes | None, str]:
    paste = which("wl-paste")
    if not paste:
        return None, "wl-paste not found"
    proc = run([paste, "--type", "image/png"])
    if proc.returncode != 0 or not proc.stdout:
        # Try any image/* the clipboard might be holding.
        listed = run([paste, "--list-types"], text=True)
        types = (listed.stdout or "").splitlines()
        image_type = next((t for t in types if t.startswith("image/")), "")
        if image_type:
            proc = run([paste, "--type", image_type])
        if proc.returncode != 0 or not proc.stdout:
            return None, "no image in clipboard"
    return proc.stdout, ""


def active_window_geom() -> tuple[str | None, str]:
    hypr = which("hyprctl")
    if not hypr:
        return None, "hyprctl not found"
    proc = run([hypr, "activewindow", "-j"], text=True)
    if proc.returncode != 0 or not (proc.stdout or "").strip():
        return None, "no active window"
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None, "hyprctl activewindow: bad JSON"
    at = data.get("at") or [0, 0]
    size = data.get("size") or [0, 0]
    try:
        x, y = int(at[0]), int(at[1])
        w, h = int(size[0]), int(size[1])
    except (TypeError, ValueError, IndexError):
        return None, "hyprctl activewindow: bad geometry"
    if w <= 0 or h <= 0:
        return None, "active window has empty geometry"
    return f"{x},{y} {w}x{h}", ""


def capture_window(geom: str | None) -> tuple[bytes | None, str]:
    if not geom:
        geom, err = active_window_geom()
        if err:
            return None, err
    return grim_geom(geom)


def copy_text(text: str) -> str:
    """Hand text to wl-copy and do not wait for it to exit.

    wl-copy stays alive as the clipboard owner. Capturing stdout/stderr or
    joining the process makes it look hung. Write stdin, detach, treat a
    still-running process as success.
    """
    copy = which("wl-copy")
    if not copy:
        return "wl-copy not found"
    try:
        proc = subprocess.Popen(
            [copy, "--type", "text/plain"],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        proc.communicate(text.encode("utf-8"), timeout=0.5)
    except subprocess.TimeoutExpired:
        return ""
    except OSError as exc:
        return str(exc)
    if proc.returncode not in (0, None):
        return "wl-copy failed"
    return ""


def atomic_write(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    tmp = path.with_name(path.name + ".tmp")
    data = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)


def load_history() -> list[dict]:
    if not HISTORY_PATH.exists():
        return []
    try:
        raw = json.loads(HISTORY_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        try:
            bad = HISTORY_PATH.with_suffix(".json.corrupt")
            os.replace(HISTORY_PATH, bad)
        except OSError:
            pass
        return []
    if isinstance(raw, list):
        items = raw
    elif isinstance(raw, dict):
        items = raw.get("items") or []
    else:
        return []
    out = []
    for item in items:
        if isinstance(item, dict) and isinstance(item.get("text"), str):
            out.append(item)
    return out


def save_history(items: list[dict], limit: int) -> None:
    trimmed = items[: max(1, int(limit))]
    atomic_write(HISTORY_PATH, {"version": 1, "items": trimmed})


def write_status(result: dict) -> None:
    atomic_write(
        STATUS_PATH,
        {
            "ok": bool(result.get("ok")),
            "chars": int(result.get("chars") or 0),
            "error": result.get("error") or "",
            "ts": int(time.time() * 1000),
        },
    )


def append_history(text: str, langs: str, mode: str, ms: int, limit: int) -> dict:
    item = {
        "id": time.strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:6],
        "ts": int(time.time() * 1000),
        "text": text,
        "chars": len(text),
        "langs": langs,
        "mode": mode,
        "ms": ms,
    }
    items = [item] + load_history()
    save_history(items, limit)
    return item


def parse_args(argv: list[str]) -> dict:
    opts = {
        "langs": DEFAULT_LANGS,
        "upscale": True,
        "geom": None,
        "history_size": DEFAULT_HISTORY,
        "copy": True,
        "history": True,
        "mode": None,
    }
    args = list(argv)
    if not args:
        return opts
    opts["mode"] = args.pop(0)
    while args:
        tok = args.pop(0)
        if tok == "--langs" and args:
            opts["langs"] = args.pop(0)
        elif tok == "--geom" and args:
            opts["geom"] = args.pop(0)
        elif tok == "--history-size" and args:
            try:
                opts["history_size"] = int(args.pop(0))
            except ValueError:
                opts["history_size"] = DEFAULT_HISTORY
        elif tok == "--upscale":
            opts["upscale"] = True
        elif tok == "--no-upscale":
            opts["upscale"] = False
        elif tok == "--no-copy":
            opts["copy"] = False
        elif tok == "--no-history":
            opts["history"] = False
        else:
            # ignore unknown flags so QML can grow without breaking
            if tok.startswith("--") and args and not args[0].startswith("--"):
                args.pop(0)
    return opts


def ocr_main(argv: list[str]) -> int:
    opts = parse_args(argv)
    mode = opts["mode"]
    langs = normalize_langs(opts["langs"])
    if mode not in {"region", "clip", "screen", "window"}:
        return fail(f"unknown mode: {mode}", langs)

    started = time.monotonic()

    if mode == "region":
        image, err = capture_region(opts["geom"])
    elif mode == "clip":
        image, err = capture_clip()
    elif mode == "screen":
        image, err = capture_screen()
    else:
        image, err = capture_window(opts["geom"])

    if err:
        ms = int((time.monotonic() - started) * 1000)
        return fail(err, langs, ms)
    if not image:
        ms = int((time.monotonic() - started) * 1000)
        return fail("empty capture", langs, ms)

    image = ensure_png(image)
    if image[:8] != PNG_SIG:
        ms = int((time.monotonic() - started) * 1000)
        return fail("capture is not a PNG", langs, ms)

    image, _did, _tool = maybe_upscale(image, opts["upscale"])
    text, _conf, count, err = pick_best(image, langs)
    ms = int((time.monotonic() - started) * 1000)

    if err and not text:
        return fail(err, langs, ms)
    if not text:
        return fail("no text found", langs, ms)

    if opts["history"]:
        append_history(text, langs, mode, ms, opts["history_size"])

    copy_err = ""
    if opts["copy"]:
        copy_err = copy_text(text)

    payload = {
        "ok": True,
        "text": text,
        "chars": len(text),
        "langs": langs,
        "error": copy_err,
        "ms": ms,
        "words": count,
    }
    write_status(payload)
    return emit(payload, 0 if not copy_err else 1)


def history_main(argv: list[str]) -> int:
    if not argv or argv[0] in {"list", "ls"}:
        items = load_history()
        return emit({"ok": True, "items": items, "error": ""}, 0)

    cmd = argv[0]
    if cmd == "delete":
        if len(argv) < 2:
            return emit({"ok": False, "error": "history delete needs an id"}, 1)
        target = argv[1]
        items = [it for it in load_history() if str(it.get("id")) != target]
        save_history(items, max(len(items), 1))
        return emit({"ok": True, "items": items, "error": ""}, 0)

    if cmd == "copy":
        if len(argv) < 2:
            return emit({"ok": False, "error": "history copy needs an id"}, 1)
        target = argv[1]
        for item in load_history():
            if str(item.get("id")) == target:
                err = copy_text(item.get("text") or "")
                if err:
                    return emit({"ok": False, "error": err}, 1)
                return emit({"ok": True, "id": target, "chars": item.get("chars", 0), "error": ""}, 0)
        return emit({"ok": False, "error": "not found"}, 1)

    return emit({"ok": False, "error": f"unknown history command: {cmd}"}, 1)


def main() -> int:
    argv = sys.argv[1:]
    if not argv or argv[0] in {"-h", "--help"}:
        sys.stderr.write(__doc__ or "")
        return 2 if not argv else 0
    if argv[0] == "history":
        return history_main(argv[1:])
    return ocr_main(argv)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
    except Exception as exc:  # noqa: BLE001 — last-resort JSON error
        try:
            fail(str(exc))
        except Exception:
            pass
        raise SystemExit(1)
