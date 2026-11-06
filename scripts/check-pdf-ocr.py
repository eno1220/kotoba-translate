"""Check Docling OCR region selection without loading model weights."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KotobaTranslate/Resources'))
from docling_core.types.doc import BoundingBox, CoordOrigin, DocItemLabel, Size
from docling.datamodel.base_models import Cluster, LayoutPrediction, Page, PagePredictions
from docling.models.factories import get_ocr_factory
from pdf_ocr import TranslationOcrModel, translation_ocr_options

options = translation_ocr_options()
# Factory dispatch must resolve the exact options type used by the real pipeline.
factory = get_ocr_factory(allow_external_plugins=False)
model = factory.create_instance(options=options, enabled=False, artifacts_path=None,
                                accelerator_options=None)
assert isinstance(model, TranslationOcrModel)


def cluster(number, label, left):
    return Cluster(id=number, label=label,
                   bbox=BoundingBox(l=left, t=20, r=left+60, b=80, coord_origin=CoordOrigin.TOPLEFT))


layout = LayoutPrediction(clusters=[cluster(0, DocItemLabel.TEXT, 20),
                                    cluster(1, DocItemLabel.PICTURE, 200),
                                    cluster(2, DocItemLabel.TABLE, 380)])
page = Page(page_no=1, size=Size(width=600, height=800),
            predictions=PagePredictions(layout=layout))
# With no backend, Docling treats each layout region as requiring OCR (a scan).
rects = model.get_ocr_rects(page)
assert len(rects) == 2
assert any(rect.l <= 20 and rect.r >= 80 for rect in rects), 'Scanned text must retain OCR'
assert any(rect.l <= 380 and rect.r >= 440 for rect in rects), 'Scanned table must retain OCR'
assert all(not (rect.l <= 200 and rect.r >= 260) for rect in rects), 'Picture must not receive OCR'
assert page.predictions.layout is layout and len(layout.clusters) == 3, 'Layout must remain intact'
page.predictions.layout = LayoutPrediction(clusters=[cluster(0, DocItemLabel.PICTURE, 20)])
assert model.get_ocr_rects(page) == []
print('Docling OCR region selection, table/text preservation and factory dispatch: passed')
