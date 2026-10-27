#!/usr/bin/env python3
"""
AI Pulse Python SDK & Reporter (Zero Dependencies)
==================================================
Allows any Python script, LLM Agent (LangGraph, AutoGen, CrewAI, DeepSeek, Grok Bot),
or training pipeline to report real-time task progress to AI Pulse on macOS.

Usage Example:
--------------
    from ai_pulse import AIPulseTask

    with AIPulseTask(
        task_id="deepseek-batch-1",
        app_name="DeepSeek",
        task_title="批量分析 1688 供应商报价",
        workspace="market-research",
        model_name="DeepSeek-R1"
    ) as task:
        task.update("Step 1/3 · 正在抓取页面...", status="running")
        # ... do work ...
        task.update("Step 2/3 · 正在交叉验证数据...", status="running")
    # Automatically marks status="completed" on exit (or "error" if an exception occurs)!
"""

import json
import os
import time
from pathlib import Path
from typing import Optional


class AIPulseTask:
    def __init__(
        self,
        task_id: str,
        app_name: str = "Custom AI Agent",
        task_title: str = "AI 自动化任务",
        workspace: str = "default",
        full_workspace_path: str = "",
        model_name: str = "Custom-LLM",
        bundle_id: str = "com.apple.Terminal",
        app_path: str = "/System/Applications/Utilities/Terminal.app",
    ):
        self.task_id = task_id
        self.app_name = app_name
        self.task_title = task_title
        self.workspace = workspace
        self.full_workspace_path = full_workspace_path or os.getcwd()
        self.model_name = model_name
        self.bundle_id = bundle_id
        self.app_path = app_path
        self.status_dir = Path.home() / ".ai-pulse" / "status"
        self.status_dir.mkdir(parents=True, exist_ok=True)
        self.file_path = self.status_dir / f"{self.task_id}.json"

    def update(
        self,
        status_detail: str,
        status: str = "running",
        task_title: Optional[str] = None,
    ) -> None:
        if task_title:
            self.task_title = task_title
        payload = {
            "id": self.task_id,
            "appName": self.app_name,
            "bundleId": self.bundle_id,
            "appPath": self.app_path,
            "taskTitle": self.task_title,
            "workspace": self.workspace,
            "fullWorkspacePath": self.full_workspace_path,
            "statusDetail": status_detail,
            "modelName": self.model_name,
            "status": status,
            "updatedAt": time.time(),
            "isAppRunning": True,
        }
        tmp_path = self.file_path.with_suffix(".json.tmp")
        tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        tmp_path.replace(self.file_path)

    def complete(self, detail: str = "任务已完成") -> None:
        self.update(detail, status="completed")

    def wait_for_user(self, detail: str = "等待人工确认或输入") -> None:
        self.update(detail, status="waiting")

    def fail(self, detail: str = "任务执行异常") -> None:
        self.update(detail, status="error")

    def remove(self) -> None:
        if self.file_path.exists():
            self.file_path.unlink()

    def __enter__(self) -> "AIPulseTask":
        self.update("正在启动任务...", status="running")
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> bool:
        if exc_type is not None:
            self.fail(f"异常退出: {exc_val}")
        else:
            self.complete("任务已顺利完成")
        return False


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Emit a task status update to AI Pulse.")
    parser.add_argument("--id", required=True, help="Unique task identifier")
    parser.add_argument("--app", default="Custom Bot", help="Display name of the AI tool")
    parser.add_argument("--title", required=True, help="Task title or prompt")
    parser.add_argument("--detail", default="正在运行...", help="Current step or detail")
    parser.add_argument("--status", default="running", choices=["running", "waiting", "completed", "error", "idle"])
    parser.add_argument("--workspace", default="default", help="Project or workspace name")
    parser.add_argument("--model", default="AI-Agent", help="Model name badge")
    args = parser.parse_args()

    reporter = AIPulseTask(
        task_id=args.id,
        app_name=args.app,
        task_title=args.title,
        workspace=args.workspace,
        model_name=args.model,
    )
    reporter.update(status_detail=args.detail, status=args.status)
    print(f"✅ Reported [{args.app}] ({args.status}) -> {reporter.file_path}")
