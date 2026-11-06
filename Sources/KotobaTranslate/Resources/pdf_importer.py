"""One-shot, offline Docling PDF import; stdout is JSON Lines only."""
import json
import os
from pathlib import Path
import sys

PROTOCOL = sys.stdout
sys.stdout = sys.stderr
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"


def emit(event, **values):
    PROTOCOL.write(json.dumps(dict(event=event, **values), ensure_ascii=False) + "\n")
    PROTOCOL.flush()


class ImportFailure(Exception):
    def __init__(self, code):
        self.code = code


def convert(path):
    if path.stat().st_size > 200 * 1024 * 1024:
        raise ImportFailure("too_large")
    import pypdfium2 as pdfium

    try:
        with pdfium.PdfDocument(path) as pdf:
            pages = len(pdf)
    except pdfium.PdfiumError as error:
        raise ImportFailure("locked" if error.err_code == 4 else "unreadable") from error
    if pages > 1000:
        raise ImportFailure("too_large")
    if pages == 0:
        raise ImportFailure("empty")
    emit("progress", current=0, total=pages)

    from docling.datamodel.base_models import ConversionStatus, InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions, TableFormerMode
    from docling.datamodel.progress import ConversionProgressKind
    from docling.datamodel.settings import settings
    from docling.document_converter import DocumentConverter, PdfFormatOption
    from pdf_ocr import translation_ocr_options

    # An explicit local directory prevents Docling's first-use model downloads.
    artifacts = settings.artifacts_path or settings.cache_dir / "models"
    if not artifacts.is_dir():
        raise ImportFailure("setup")
    options = PdfPipelineOptions(artifacts_path=artifacts, enable_remote_services=False)
    options.ocr_options = translation_ocr_options()
    options.table_structure_options.mode = TableFormerMode.ACCURATE
    # The editor consumes text and Markdown tables only. These are already off
    # by default, but keep the conversion contract explicit across upgrades.
    options.do_picture_classification = False
    options.do_picture_description = False
    options.do_chart_extraction = False
    options.do_code_enrichment = False
    options.do_formula_enrichment = False
    options.generate_page_images = False
    options.generate_picture_images = False
    options.generate_parsed_pages = False

    def progress(event):
        if event.kind == ConversionProgressKind.PAGE_COMPLETED:
            emit("progress", current=event.completed_pages, total=event.total_pages)

    converter = DocumentConverter(
        allowed_formats=[InputFormat.PDF],
        format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=options)},
    )
    result = converter.convert(path, max_num_pages=1000, max_file_size=200 * 1024 * 1024,
                               progress_callback=progress)
    try:
        # Never silently accept partial conversion (e.g. a failed scanned page).
        if result.status != ConversionStatus.SUCCESS:
            raise ImportFailure("conversion")
        markdown = result.document.export_to_markdown(image_placeholder="").strip()
        if len(markdown) > 2_000_000:
            raise ImportFailure("too_large")
        if not markdown:
            raise ImportFailure("empty")
        emit("result", markdown=markdown, pages=pages)
    finally:
        result.input.release()


def main():
    try:
        convert(Path(sys.argv[1]))
    except ImportFailure as error:
        emit("error", code=error.code)
        return 1
    except (ImportError, FileNotFoundError):
        emit("error", code="setup")
        return 1
    except Exception as error:
        # Do not log source text or the resulting Markdown.
        print(f"Docling PDF import failed ({type(error).__name__})", file=sys.stderr)
        emit("error", code="conversion")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
