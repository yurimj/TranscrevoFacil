import argparse
import json
import sys


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")

    parser = argparse.ArgumentParser(description="Transcricao local com faster-whisper.")
    parser.add_argument("--file", required=True)
    parser.add_argument("--model", default="small")
    parser.add_argument("--device", default="cpu")
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--cpu-threads", type=int, default=0)
    parser.add_argument("--num-workers", type=int, default=1)
    parser.add_argument("--language", default=None)
    parser.add_argument("--task", default="transcribe", choices=["transcribe", "translate"])
    args = parser.parse_args()

    try:
        from faster_whisper import WhisperModel
    except ImportError:
        print(
            "Dependencia ausente: instale com `pip install faster-whisper`.",
            file=sys.stderr,
        )
        return 2

    model = WhisperModel(
        args.model,
        device=args.device,
        compute_type=args.compute_type,
        cpu_threads=args.cpu_threads,
        num_workers=args.num_workers,
    )

    segments, info = model.transcribe(
        args.file,
        language=args.language or None,
        task=args.task,
        vad_filter=True,
    )

    result_segments = []
    for segment in segments:
        result_segments.append(
            {
                "id": segment.id,
                "start": segment.start,
                "end": segment.end,
                "text": segment.text.strip(),
            }
        )

    payload = {
        "text": "\n".join(segment["text"] for segment in result_segments).strip(),
        "language": info.language,
        "language_probability": info.language_probability,
        "duration": info.duration,
        "segments": result_segments,
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
