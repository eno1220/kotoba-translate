"""Docling OCR restricted to content the translation editor can consume."""
from typing import ClassVar

from docling_core.types.doc import DocItemLabel
from docling.datamodel.pipeline_options import OcrMacOptions
from docling.models.factories import get_ocr_factory
from docling.models.stages.ocr.ocr_mac_model import OcrMacModel


class TranslationOcrOptions(OcrMacOptions):
    kind: ClassVar[str] = "kotoba_text_ocr"


class TranslationOcrModel(OcrMacModel):
    @classmethod
    def get_options_type(cls):
        return TranslationOcrOptions

    def get_ocr_rects(self, page):
        layout = page.predictions.layout
        if layout is None:
            return super().get_ocr_rects(page)
        # Filter before Docling merges OCR regions, so a picture cannot enlarge
        # a neighbouring text/table crop. Shallow copies retain the backend and
        # leave the original layout intact for reading order and table analysis.
        clusters = [cluster for cluster in layout.clusters if cluster.label != DocItemLabel.PICTURE]
        text_layout = layout.model_copy(update={"clusters": clusters})
        predictions = page.predictions.model_copy(update={"layout": text_layout})
        text_page = page.model_copy(update={"predictions": predictions})
        return super().get_ocr_rects(text_page)


def translation_ocr_options():
    factory = get_ocr_factory(allow_external_plugins=False)
    if TranslationOcrOptions.kind not in factory.registered_kind:
        factory.register(TranslationOcrModel, plugin_name="kotoba", plugin_module_name=__name__)
    return TranslationOcrOptions(lang=[], recognition="accurate")
