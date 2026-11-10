"""Public interface of ``day_cycle`` (spec §2). Other modules import from this package root only."""

from app.modules.day_cycle.dependencies import ensure_current_day, get_day_service
from app.modules.day_cycle.pipeline import (
    ClosePipeline,
    NullPredictorHook,
    NullReportGenerator,
    PipelineDeps,
    PipelineScheduler,
    PredictorHook,
    ReportGenerator,
    run_pipelines,
)
from app.modules.day_cycle.schemas import CloseMode, CloseResultDTO, DayDTO, DayState, DaySummary
from app.modules.day_cycle.service import DayService

__all__ = [
    "CloseMode",
    "ClosePipeline",
    "CloseResultDTO",
    "DayDTO",
    "DayService",
    "DayState",
    "DaySummary",
    "NullPredictorHook",
    "NullReportGenerator",
    "PipelineDeps",
    "PipelineScheduler",
    "PredictorHook",
    "ReportGenerator",
    "ensure_current_day",
    "get_day_service",
    "run_pipelines",
]
