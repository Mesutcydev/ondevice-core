"""Compile production Foundation contracts without device-only dependencies."""
from pathlib import Path
import re
import sys

root, destination, tests = map(Path, sys.argv[1:])
service = (root / "IOSLocalLLM/Services/CodingAssistantService.swift").read_text()


def declaration(source: str, pattern: str) -> str:
    matches = list(re.finditer(pattern, source, re.MULTILINE | re.DOTALL))
    assert len(matches) == 1, "Production contract anchor changed"
    return matches[0].group()


profile = declaration(service, r"^enum GGUFGenerationProfile:.*?^}")
context = service[service.index("    struct PromptContext {"):
                  service.index("    /// Chat templates for Qwen 3.5")]
trim = service[service.index("    nonisolated static func trimToInputBudget("):
               service.index("    // MARK: - Vision input helper")]
constants = "\n".join(declaration(service, rf'    nonisolated static let {name} = """.*?\n    """')
                       for name in ["systemPrompt", "compactGroundingPrompt", "responseFormattingPrompt"])
(destination / "AssistantContextContract.swift").write_text(
    "import Foundation\n" + profile + "\nextension CodingAssistantService {\n"
    + constants + "\n" + context + trim + "\n}\n")

store = (root / "IOSLocalLLM/Models/ConversationStore.swift").read_text()
(destination / "ConversationContextContract.swift").write_text(
    "import Foundation\n" + store[store.index("struct ConversationContextMemory:"):])

policy = (root / "IOSLocalLLM/Models/AIContentPolicy.swift").read_text()
text_rule = declaration(policy, r'    nonisolated static let textInstructions = """.*?\n    """')
(destination / "ContextPolicyContract.swift").write_text("enum AIContentPolicy {\n" + text_rule + "\n}\n")
tools = (root / "IOSLocalLLM/Services/ToolRunner.swift").read_text()
addenda = "\n".join(declaration(tools, rf'    static let {name} = """.*?\n    """')
                     for name in ["unavailablePromptAddendum", "coreAISystemPromptAddendum", "systemPromptAddendum"])
(destination / "ToolPromptContract.swift").write_text("enum ToolRunner {\n" + addenda + "\n}\n")

# Later methods also test other runtime policies and the device bridge. Select
# the Foundation profile/prompt tests, rather than mocking those runtimes.
profile_tests = (root / "IOSLocalLLMTests/GGUFGenerationProfileTests.swift").read_text()
profile_tests = profile_tests[:profile_tests.index("    func test_prefixCache_reusesSharedTokens()")]
(tests / "GGUFGenerationProfileTests.swift").write_text(
    "import XCTest\n@testable import IOSLocalLLM\n"
    + profile_tests[profile_tests.index("final class GGUFGenerationProfileTests:"):] + "}\n")
