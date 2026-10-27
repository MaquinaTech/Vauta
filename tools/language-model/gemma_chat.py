# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López
"""Reference chat rendering for Gemma 4 (pinned chat_template.jinja at ee0ef602) with Hugging Face `tokenizers`. Tool only."""
import json
import jinja2
from jinja2.sandbox import ImmutableSandboxedEnvironment
from tokenizers import Tokenizer


def make_env(template_path):
    env = ImmutableSandboxedEnvironment(trim_blocks=True, lstrip_blocks=True, extensions=["jinja2.ext.loopcontrols"])

    def raise_exception(msg):
        raise jinja2.TemplateError(msg)

    env.globals["raise_exception"] = raise_exception
    env.globals["strftime_now"] = lambda fmt: "2026-10-12"
    env.filters["tojson"] = lambda x, **k: json.dumps(x, ensure_ascii=False)
    return env.from_string(open(template_path, encoding="utf-8").read())


class GemmaChat:
    def __init__(self, tokenizer_json, template_path):
        self.tok = Tokenizer.from_file(tokenizer_json)
        self.template = make_env(template_path)

    def render(self, messages, add_generation_prompt=True):
        return self.template.render(messages=messages, add_generation_prompt=add_generation_prompt, bos_token="<bos>", eos_token="<eos>",
                                    enable_thinking=False, tools=None)

    def ids(self, messages, add_generation_prompt=True):
        text = self.render(messages, add_generation_prompt)
        return self.tok.encode(text, add_special_tokens=False).ids, text
