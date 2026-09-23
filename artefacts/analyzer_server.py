#!/usr/bin/env python3
# ============================================================================
#  Пример analyzer_server.py с загрузкой готового файла правил
#  /etc/presidio/custom_recognizers.yaml (гайд 09, метод подстановки).
#
#  База — analyzer_server.py из гайда 04_add_presidio.md.
#  Отличие: при старте грузятся 250 кастомных распознавателей из YAML
#  (artefacts/custom_recognizers.yaml, снапшот guardrails-llm-filter).
#
#  Файл правил (вариант без Docker):
#     sudo cp artefacts/custom_recognizers.yaml /etc/presidio/custom_recognizers.yaml
#     sudo chown litellm:litellm /etc/presidio/custom_recognizers.yaml
#
#  Запуск (как в гайде 04): gunicorn --bind 127.0.0.1:5002 --workers 2 \
#     --timeout 120 analyzer_server:app   (systemd-служба presidio-analyzer)
# ============================================================================

import logging

import yaml
from flask import Flask, jsonify, request
from presidio_analyzer import AnalyzerEngine, PatternRecognizer
from presidio_analyzer.nlp_engine import NlpEngineProvider

# --- Путь к файлу кастомных правил (гайд 09) ---
CUSTOM_RECOGNIZERS_FILE = "/etc/presidio/custom_recognizers.yaml"

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("presidio-analyzer-custom")

# ---------------------------------------------------------------------------
# NLP-движок и analyzer — как в гайде 04
# ---------------------------------------------------------------------------
NLP_CONF = {
    "nlp_engine_name": "spacy",
    "models": [
        {"lang_code": "en", "model_name": "en_core_web_md"},
        {"lang_code": "ru", "model_name": "ru_core_news_md"},
    ],
}

nlp_engine = NlpEngineProvider(nlp_configuration=NLP_CONF).create_engine()

# registry НЕ передаём: AnalyzerEngine сам создаёт реестр и грузит
# предустановленные распознаватели (Email, IP, CREDIT_CARD, ...) для en+ru.
# Кастомные правила добавляются ниже через analyzer.registry.add_recognizer.
analyzer = AnalyzerEngine(
    nlp_engine=nlp_engine,
    supported_languages=["en", "ru"],
)


# ---------------------------------------------------------------------------
# Загрузка кастомных правил из YAML (гайд 09)
# ---------------------------------------------------------------------------
def _load_custom_recognizers(path):
    """Загрузить распознаватели из custom_recognizers.yaml.

    Формат файла: recognizers: [{name, supported_entity, patterns,
    supported_languages: [ru]}]. PatternRecognizer принимает только
    singular supported_language — разворачиваем список языков сами.
    Одно битое правило не должно ронять сервис.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        logger.warning("custom recognizers: %s не найден, пропускаю", path)
        return []

    entries = (data or {}).get("recognizers") or []
    recognizers = []
    for entry in entries:
        # plural -> singular: по распознавателю на язык
        languages = entry.pop("supported_languages", None) or [
            entry.get("supported_language", "ru")
        ]
        for language in languages:
            try:
                recognizers.append(
                    PatternRecognizer.from_dict(
                        {**entry, "supported_language": language}
                    )
                )
            except Exception as exc:
                logger.warning(
                    "custom recognizer %s (%s) пропущен: %s",
                    entry.get("name"), language, exc,
                )
    logger.info("custom recognizers: загружено %d из %d", len(recognizers), len(entries))
    return recognizers


for _rec in _load_custom_recognizers(CUSTOM_RECOGNIZERS_FILE):
    analyzer.registry.add_recognizer(_rec)


# ---------------------------------------------------------------------------
# HTTP API — как в гайде 04
# ---------------------------------------------------------------------------
app = Flask(__name__)


@app.route("/health")
def health():
    return "Presidio Analyzer is up"


@app.route("/analyze", methods=["POST"])
def analyze():
    body = request.get_json(force=True) or {}
    text = body.get("text")
    language = body.get("language")
    if not text or not language:
        return jsonify(error="No text or language provided"), 400

    results = analyzer.analyze(
        text=text,
        language=language,
        entities=body.get("entities"),
        score_threshold=body.get("score_threshold", 0.35),
        correlation_id=body.get("correlation_id"),
        return_decision_process=body.get("return_decision_process", False),
    )
    return jsonify([r.to_dict() for r in results])


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5002)
