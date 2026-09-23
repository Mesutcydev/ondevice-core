import XCTest
import UIKit
@testable import IOSLocalLLM

final class LocalAPIServerTests: XCTestCase {
    func testPortValidation() {
        XCTAssertNil(LocalAPIValidation.validPort(1023))
        XCTAssertEqual(LocalAPIValidation.validPort(11434), 11434)
        XCTAssertEqual(LocalAPIValidation.validPort(65535), 65535)
        XCTAssertNil(LocalAPIValidation.validPort(65536))
    }

    func testModelAliases() {
        XCTAssertTrue(LocalAPIValidation.modelMatches("qwen", id: "qwen", repoID: "org/qwen"))
        XCTAssertTrue(LocalAPIValidation.modelMatches("org/qwen", id: "qwen", repoID: "org/qwen"))
        XCTAssertFalse(LocalAPIValidation.modelMatches("other", id: "qwen", repoID: "org/qwen"))
    }

    func testModelDetailPathDecodesRepositoryID() {
        XCTAssertEqual(LocalAPIValidation.modelID(fromDetailPath: "/v1/models/org%2Fqwen"), "org/qwen")
        XCTAssertEqual(LocalAPIValidation.modelID(fromDetailPath: "/v1/models/qwen"), "qwen")
        XCTAssertNil(LocalAPIValidation.modelID(fromDetailPath: "/v1/models/"))
        XCTAssertNil(LocalAPIValidation.modelID(fromDetailPath: "/v1/models/%ZZ"))
    }

    func testAiderConfigurationUsesBoundedLimitsAndNoSecret() throws {
        let export = LocalAPIAiderConfiguration.export(
            modelID: "org/model",
            inputBudget: 3_072,
            outputLimit: 512,
            supportsTools: true,
            supportsVision: false,
            baseURL: "http://192.0.2.1:11434/v1"
        )
        XCTAssertEqual(export["model"] as? String, "openai/org/model")
        XCTAssertEqual(export["max_output_tokens"] as? Int, 512)
        let metadataJSON = try XCTUnwrap(export["metadata_json"] as? String)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: [String: Any]])
        XCTAssertEqual(metadata["openai/org/model"]?["max_input_tokens"] as? Int, 3_072)
        XCTAssertEqual(metadata["openai/org/model"]?["supports_function_calling"] as? Bool, true)
        let command = try XCTUnwrap(export["launch_command"] as? String)
        XCTAssertTrue(command.contains("AIDER_API_KEY=YOUR_LOCAL_API_KEY"))
        XCTAssertTrue(command.contains("192.0.2.1:11434/v1"))
    }

    func testTunnelInterfacesAreExcludedFromLANAddresses() {
        XCTAssertTrue(LocalAPIValidation.isReachableLANInterface("en0"))
        XCTAssertTrue(LocalAPIValidation.isReachableLANInterface("bridge100"))
        XCTAssertFalse(LocalAPIValidation.isReachableLANInterface("utun4"))
        XCTAssertFalse(LocalAPIValidation.isReachableLANInterface("ipsec0"))
        XCTAssertFalse(LocalAPIValidation.isReachableLANInterface("pdp_ip0"))
    }

    func testRemoteInferenceLimitsBoundToolSelection() {
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: 65_536,
                toolCallingEnabled: true
            ),
            256
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: 128,
                toolCallingEnabled: true
            ),
            128
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: nil,
                toolCallingEnabled: true
            ),
            256
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: 65_536,
                toolCallingEnabled: false
            ),
            4_096
        )
        XCTAssertNil(
            LocalAPIInferencePolicy.maxTokens(
                requested: nil,
                toolCallingEnabled: false
            )
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: 2_048,
                toolCallingEnabled: false,
                configuredLimit: 512
            ),
            512
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: nil,
                toolCallingEnabled: false,
                configuredLimit: 512
            ),
            512
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.maxTokens(
                requested: 2_048,
                toolCallingEnabled: true,
                configuredLimit: 512
            ),
            256
        )
    }

    func testRemoteInferenceDeadlinesCoverToolsAndPlainResponses() {
        XCTAssertEqual(
            LocalAPIInferencePolicy.deadline(toolCallingEnabled: true),
            .seconds(30)
        )
        XCTAssertEqual(
            LocalAPIInferencePolicy.deadline(toolCallingEnabled: false),
            .seconds(90)
        )
    }

    func testToolDecisionBuffersOnlyPotentialToolSyntax() {
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision(""))
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision("  {"))
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision("<tool"))
        XCTAssertTrue(LocalAPIToolCalling.shouldBufferForToolDecision("```json\n{"))
        XCTAssertFalse(
            LocalAPIToolCalling.shouldBufferForToolDecision(
                "The weather is sunny."
            )
        )
        XCTAssertFalse(
            LocalAPIToolCalling.shouldBufferForToolDecision(
                #"{"answer":"This is ordinary JSON output, not a tool call, and it is long enough to make that decision without buffering the whole generation."}"#
            )
        )
        XCTAssertTrue(
            LocalAPIToolCalling.shouldBufferForToolDecision(
                #"{"tool_calls":[{"name":"get_weather","arguments":{"city":"Istanbul","units":"metric","include_forecast":true}}]}"#
            )
        )
    }

    func testOpenAIRequestDecodesTextMessagesAndOverrides() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"system","content":"Be concise."},
            {"role":"user","content":"Hello"}
          ],
          "stream":true,
          "max_tokens":128,
          "temperature":0.2,
          "top_p":0.8
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(request.model, "qwen")
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertTrue(request.stream)
        XCTAssertEqual(request.maxTokens, 128)
        XCTAssertEqual(request.temperature, 0.2)
        XCTAssertEqual(request.topP, 0.8)
    }

    func testOpenAIAcceptsEmptyTools() throws {
        let data = Data("""
        {"model":"qwen","messages":[{"role":"user","content":"Hi"}],"tools":[]}
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(request.messages.map(\.content), ["Hi"])
    }

    func testOpenAIDecodesFunctionTools() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[{"role":"user","content":"What is the weather in Cairo?"}],
          "tools":[{
            "type":"function",
            "function":{
              "name":"get_weather",
              "description":"Get weather",
              "parameters":{
                "type":"object",
                "properties":{"city":{"type":"string"}},
                "required":["city"]
              }
            }
          }],
          "tool_choice":"required",
          "parallel_tool_calls":false
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(request.tools.map(\.name), ["get_weather"])
        XCTAssertEqual(request.tools.first?.description, "Get weather")
        XCTAssertEqual(request.toolChoice, .required)
        XCTAssertFalse(request.parallelToolCalls)
    }

    func testOpenAIAcceptsHermesAgentCustomProviderOptions() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"system","content":"You are Hermes Agent."},
            {"role":"user","content":"Inspect the workspace."}
          ],
          "tools":[{
            "type":"function",
            "function":{
              "name":"terminal",
              "description":"Run a shell command",
              "parameters":{
                "type":"object",
                "properties":{"command":{"type":"string"}},
                "required":["command"]
              }
            }
          }],
          "stream":true,
          "stream_options":{"include_usage":true},
          "max_tokens":65536,
          "reasoning_effort":"none",
          "think":false,
          "options":{"num_ctx":64000}
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertTrue(request.stream)
        XCTAssertEqual(request.maxTokens, 65_536)
        XCTAssertEqual(request.tools.map(\.name), ["terminal"])
        XCTAssertEqual(request.toolChoice, .auto)

        let inferenceMessages = LocalAPIToolCalling.messages(
            from: request.messages,
            tools: request.tools,
            choice: request.toolChoice,
            parallelToolCalls: request.parallelToolCalls
        )
        XCTAssertFalse(inferenceMessages.contains { $0.role == .system })
        XCTAssertTrue(inferenceMessages.last?.content.contains("You are Hermes Agent.") == true)
        XCTAssertTrue(inferenceMessages.last?.content.contains("Inspect the workspace.") == true)
    }

    func testOpenAIDecodesHermesTextPartArraysAndToolResult() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"system","content":"You are in agent mode."},
            {"role":"user","content":[{"type":"text","text":"show me the codebase"}]},
            {
              "role":"assistant",
              "content":[{"type":"text","text":"I will inspect the root."}],
              "tool_calls":[{
                "id":"tool_1",
                "type":"function",
                "function":{"name":"terminal","arguments":"{\\"command\\":\\"find . -maxdepth 2\\"}"}
              }]
            },
            {
              "role":"tool",
              "tool_call_id":"tool_1",
              "content":[{"type":"text","text":"README.md\\nsrc/main.py"}]
            },
            {"role":"user","content":[{"type":"input_text","text":"continue"}]}
          ],
          "tools":[{
            "type":"function",
            "function":{
              "name":"terminal",
              "description":"Run a command",
              "parameters":{"type":"object"}
            }
          }],
          "stream":true,
          "messagesOptions":{"precompleted":true}
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(
            request.messages.map(\.role),
            [.system, .user, .assistant, .user, .user]
        )
        XCTAssertEqual(request.messages[1].content, "show me the codebase")
        XCTAssertTrue(request.messages[2].content.contains("I will inspect the root."))
        XCTAssertTrue(request.messages[2].content.contains("terminal"))
        XCTAssertTrue(request.messages[3].content.contains("README.md\nsrc/main.py"))
        XCTAssertEqual(request.messages[4].content, "continue")
    }

    func testOpenAIRejectsUnknownNamedToolChoice() {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[{"role":"user","content":"Hi"}],
          "tools":[{
            "type":"function",
            "function":{"name":"known","parameters":{"type":"object"}}
          }],
          "tool_choice":{"type":"function","function":{"name":"unknown"}}
        }
        """.utf8)
        XCTAssertThrowsError(try LocalAPIChatRequest.decodeOpenAI(data))
    }

    func testOpenAIDecodesToolCallHistoryAndResult() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"user","content":"Weather?"},
            {
              "role":"assistant",
              "content":null,
              "tool_calls":[{
                "id":"call_1",
                "type":"function",
                "function":{"name":"get_weather","arguments":"{\\"city\\":\\"Cairo\\"}"}
              }]
            },
            {"role":"tool","tool_call_id":"call_1","content":"31 C, sunny"}
          ]
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertEqual(request.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertTrue(request.messages[1].content.contains("get_weather"))
        XCTAssertTrue(request.messages[2].content.contains("31 C, sunny"))
    }

    func testOpenAIPreservesAssistantTextAlongsideToolCallHistory() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[{
            "role":"assistant",
            "content":"I will inspect that.",
            "tool_calls":[{
              "id":"call_1",
              "type":"function",
              "function":{"name":"terminal","arguments":"{\\"command\\":\\"pwd\\"}"}
            }]
          }]
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAI(data)
        XCTAssertTrue(request.messages[0].content.contains("I will inspect that."))
        XCTAssertTrue(request.messages[0].content.contains("terminal"))
        XCTAssertTrue(request.messages[0].content.contains("call_1"))
    }

    func testToolCallingPromptAndParser() {
        let tool = LocalAPIToolDefinition(
            name: "get_weather",
            description: "Get weather",
            parametersJSON: #"{"properties":{"city":{"type":"string"}},"type":"object"}"#
        )
        let messages = LocalAPIToolCalling.messages(
            from: [ChatMessage(role: .user, content: "Weather in Cairo?")],
            tools: [tool],
            choice: .auto,
            parallelToolCalls: true
        )
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertTrue(messages.first?.content.contains("get_weather") == true)
        XCTAssertTrue(messages.first?.content.contains("Weather in Cairo?") == true)

        let calls = LocalAPIToolCalling.parse(
            """
            <tool_call>
            {"tool_calls":[{"name":"get_weather","arguments":{"city":"Cairo"}}]}
            </tool_call>
            """,
            tools: [tool],
            parallelToolCalls: true
        )
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "get_weather")
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"city":"Cairo"}"#)
    }

    func testToolCallingParserCollectsParallelHermesCalls() {
        let tools = [
            LocalAPIToolDefinition(
                name: "read_file",
                description: nil,
                parametersJSON: #"{"type":"object"}"#
            ),
            LocalAPIToolDefinition(
                name: "terminal",
                description: nil,
                parametersJSON: #"{"type":"object"}"#
            )
        ]
        let calls = LocalAPIToolCalling.parse(
            """
            <tool_call>{"name":"read_file","arguments":{"path":"README.md"}}</tool_call>
            <tool_call>{"name":"terminal","parameters":{"command":"pwd"}}</tool_call>
            """,
            tools: tools,
            parallelToolCalls: true
        )
        XCTAssertEqual(calls.map(\.name), ["read_file", "terminal"])
        XCTAssertEqual(calls[1].argumentsJSON, #"{"command":"pwd"}"#)
    }

    func testToolCallingParserAcceptsAppStyleArgs() {
        let tool = LocalAPIToolDefinition(
            name: "get_weather",
            description: nil,
            parametersJSON: #"{"type":"object"}"#
        )
        let calls = LocalAPIToolCalling.parse(
            #"{"name":"get_weather","args":{"city":"Asyut"}}"#,
            tools: [tool],
            parallelToolCalls: false
        )
        XCTAssertEqual(calls.first?.name, "get_weather")
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"city":"Asyut"}"#)
    }

    func testOpenAIResponsesDecodesTextInputBlocks() throws {
        let data = Data("""
        {
          "model":"qwen",
          "instructions":"Be concise.",
          "input":[{
            "role":"user",
            "content":[{"type":"input_text","text":"Hi"}]
          }],
          "tools":[],
          "max_output_tokens":64
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAIResponses(data)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertEqual(request.messages.map(\.content), ["Be concise.", "Hi"])
        XCTAssertEqual(request.maxTokens, 64)
        XCTAssertFalse(request.stream)
    }

    func testOpenAIResponsesAcceptsStringInput() throws {
        let data = Data("""
        {"model":"qwen","input":"Hi","stream":true}
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOpenAIResponses(data)
        XCTAssertEqual(request.messages.map(\.content), ["Hi"])
        XCTAssertTrue(request.stream)
    }

    func testOllamaChatDefaultsToStreaming() throws {
        let data = Data("""
        {"model":"qwen","messages":[{"role":"user","content":"Hi"}]}
        """.utf8)
        XCTAssertTrue(try LocalAPIChatRequest.decodeOllamaChat(data).stream)
    }

    func testOllamaChatCanUseCurrentModelWhenOmitted() throws {
        let data = Data("""
        {"messages":[{"role":"user","content":"Hi"}],"stream":false}
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOllamaChat(data)
        XCTAssertEqual(request.model, "")
        XCTAssertFalse(request.stream)
    }

    func testOllamaChatDecodesToolsAndObjectArgumentsHistory() throws {
        let data = Data("""
        {
          "model":"qwen",
          "messages":[
            {"role":"user","content":"Weather?"},
            {
              "role":"assistant",
              "content":"",
              "tool_calls":[{
                "function":{
                  "name":"get_weather",
                  "arguments":{"city":"Cairo"}
                }
              }]
            },
            {"role":"tool","content":"31 C, sunny"}
          ],
          "tools":[{
            "type":"function",
            "function":{
              "name":"get_weather",
              "description":"Get weather",
              "parameters":{"type":"object"}
            }
          }]
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOllamaChat(data)
        XCTAssertEqual(request.tools.map(\.name), ["get_weather"])
        XCTAssertEqual(request.toolChoice, .auto)
        XCTAssertTrue(request.messages[1].content.contains("get_weather"))
        XCTAssertTrue(request.messages[2].content.contains("31 C, sunny"))
    }

    func testOllamaGenerateBuildsSystemAndUserMessages() throws {
        let data = Data("""
        {"model":"qwen","system":"Be concise.","prompt":"Hi","stream":false}
        """.utf8)
        let request = try LocalAPIChatRequest.decodeOllamaGenerate(data)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertFalse(request.stream)
    }

    func testAnthropicRequestDecodesTextBlocksAndSystem() throws {
        let data = Data("""
        {
          "model":"qwen",
          "system":[{"type":"text","text":"Be concise."}],
          "messages":[{"role":"user","content":[{"type":"text","text":"Hello"}]}],
          "max_tokens":128,
          "stream":true
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeAnthropic(data)
        XCTAssertEqual(request.messages.map(\.role), [.system, .user])
        XCTAssertEqual(request.messages.map(\.content), ["Be concise.", "Hello"])
        XCTAssertEqual(request.maxTokens, 128)
        XCTAssertTrue(request.stream)
    }

    func testAnthropicDecodesToolsAndToolResultHistory() throws {
        let data = Data("""
        {
          "model":"qwen",
          "max_tokens":64,
          "messages":[
            {"role":"user","content":"Weather?"},
            {
              "role":"assistant",
              "content":[{
                "type":"tool_use",
                "id":"toolu_1",
                "name":"get_weather",
                "input":{"city":"Cairo"}
              }]
            },
            {
              "role":"user",
              "content":[{
                "type":"tool_result",
                "tool_use_id":"toolu_1",
                "content":"31 C, sunny"
              }]
            }
          ],
          "tools":[{
            "name":"get_weather",
            "description":"Get weather",
            "input_schema":{"type":"object"}
          }],
          "tool_choice":{"type":"auto"}
        }
        """.utf8)
        let request = try LocalAPIChatRequest.decodeAnthropic(data)
        XCTAssertEqual(request.tools.map(\.name), ["get_weather"])
        XCTAssertEqual(request.toolChoice, .auto)
        XCTAssertTrue(request.messages[1].content.contains("toolu_1"))
        XCTAssertTrue(request.messages[2].content.contains("31 C, sunny"))
    }

    func testAnthropicResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.anthropicMessage(id: "msg_test", model: "qwen", text: "hello")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "message")
        XCTAssertEqual(object["role"] as? String, "assistant")
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "hello")
    }

    func testOpenAIChunkHasCompatibilityShape() throws {
        let data = LocalAPIResponse.openAIChunk(
            id: "chatcmpl-test",
            model: "qwen",
            text: "hello",
            role: "assistant"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["object"] as? String, "chat.completion.chunk")
        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        let delta = try XCTUnwrap(choices.first?["delta"] as? [String: Any])
        XCTAssertEqual(delta["content"] as? String, "hello")
        XCTAssertEqual(delta["role"] as? String, "assistant")
    }

    func testOpenAIToolCallResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.openAIChatCompletion(
            id: "chatcmpl-test",
            model: "qwen",
            text: "",
            toolCalls: [
                LocalAPIToolCall(
                    id: "call_test",
                    name: "get_weather",
                    argumentsJSON: #"{"city":"Cairo"}"#
                )
            ]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let choices = try XCTUnwrap(object["choices"] as? [[String: Any]])
        XCTAssertEqual(choices.first?["finish_reason"] as? String, "tool_calls")
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertTrue(message["content"] is NSNull)
        let calls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
        XCTAssertEqual(function["arguments"] as? String, #"{"city":"Cairo"}"#)
    }

    func testAnthropicToolResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.anthropicToolMessage(
            id: "msg_test",
            model: "qwen",
            calls: [
                LocalAPIToolCall(
                    id: "toolu_test",
                    name: "get_weather",
                    argumentsJSON: #"{"city":"Cairo"}"#
                )
            ]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["stop_reason"] as? String, "tool_use")
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "tool_use")
        XCTAssertEqual(content.first?["id"] as? String, "toolu_test")
    }

    func testOllamaToolResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.ollamaToolCalls(
            model: "qwen",
            calls: [
                LocalAPIToolCall(
                    id: "ignored",
                    name: "get_weather",
                    argumentsJSON: #"{"city":"Cairo"}"#
                )
            ],
            done: true
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let calls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "get_weather")
        XCTAssertEqual(
            (function["arguments"] as? [String: Any])?["city"] as? String,
            "Cairo"
        )
    }

    func testOpenAIResponseHasCompatibilityShape() throws {
        let data = LocalAPIResponse.openAIResponse(
            id: "resp_test", model: "qwen", text: "hello"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["object"] as? String, "response")
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["output_text"] as? String, "hello")
        let output = try XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertEqual(output.first?["role"] as? String, "assistant")
    }

    func testOpenAIChatCompletionReportsUsage() throws {
        let data = LocalAPIResponse.openAIChatCompletion(
            id: "chatcmpl-test",
            model: "qwen",
            text: "hi",
            toolCalls: [],
            usage: (12, 34)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 12)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 34)
        XCTAssertEqual(usage["total_tokens"] as? Int, 46)
    }

    func testOpenAIChatCompletionOmitsUsageWhenUnknown() throws {
        let data = LocalAPIResponse.openAIChatCompletion(
            id: "chatcmpl-test",
            model: "qwen",
            text: "hi",
            toolCalls: []
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["usage"])
    }

    func testAnthropicMessageReportsUsage() throws {
        let data = LocalAPIResponse.anthropicMessage(
            id: "msg_test",
            model: "qwen",
            text: "hi",
            usage: (8, 16)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 8)
        XCTAssertEqual(usage["output_tokens"] as? Int, 16)
    }

    func testOllamaChatReportsEvalCountsWhenDone() throws {
        let data = LocalAPIResponse.ollamaChat(
            model: "qwen",
            text: "hi",
            done: true,
            usage: (10, 20)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["prompt_eval_count"] as? Int, 10)
        XCTAssertEqual(object["eval_count"] as? Int, 20)
    }

    func testHTTPRequestParsesQueryAndBearer() {
        let request = HTTPRequest(data: Data("""
        POST /v1/chat/completions?trace=1 HTTP/1.1\r
        Authorization: Bearer abc\r
        Content-Type: application/json\r
        Content-Length: 2\r
        \r
        {}
        """.utf8))
        XCTAssertEqual(request?.path, "/v1/chat/completions")
        XCTAssertEqual(request?.headers["authorization"], "Bearer abc")
        XCTAssertEqual(request?.body, Data("{}".utf8))
    }

    /// Pre-authentication input: an enormous Content-Length must read as
    /// "body incomplete", not overflow `header + length` and trap.
    func testHTTPRequestHugeContentLengthDoesNotTrap() {
        let request = HTTPRequest(data: Data("""
        POST /v1/chat/completions HTTP/1.1\r
        Content-Length: \(Int.max)\r
        \r
        {}
        """.utf8))
        XCTAssertNil(request)
    }

    func testHTTPRequestIdentifiesUnsupportedChunkedBody() throws {
        let request = try XCTUnwrap(HTTPRequest(data: Data("""
        POST /api/chat HTTP/1.1\r
        Transfer-Encoding:chunked\r
        \r
        """.utf8)))
        XCTAssertTrue(request.declaresChunkedBody)
        XCTAssertNil(request.body)
    }

    func testHTTPRequestPreservesPipelinedBinaryBodies() throws {
        let body = Data([0x00, 0xFF, 0x0D, 0x0A, 0x0D, 0x0A])
        var bytes = Data("POST /api/chat HTTP/1.1\r\nContent-Length: 6\r\n\r\n".utf8)
        bytes.append(body)
        bytes.append(Data("GET /v1/models HTTP/1.1\r\nConnection: close\r\n\r\n".utf8))
        let first = try XCTUnwrap(HTTPRequest.parse(data: bytes))
        XCTAssertEqual(first.request.body, body)
        XCTAssertTrue(first.request.wantsKeepAlive)
        let second = try XCTUnwrap(HTTPRequest.parse(data: Data(bytes.dropFirst(first.consumedBytes))))
        XCTAssertEqual(second.request.path, "/v1/models")
        XCTAssertFalse(second.request.wantsKeepAlive)
        XCTAssertEqual(LocalAPIServer.chunkFrame(Data("hi".utf8)), Data("2\r\nhi\r\n".utf8))
    }

    func testHeaderCanBeAuthenticatedBeforeImageBodyArrives() throws {
        let head = try XCTUnwrap(HTTPRequest.parseHeader(data: Data(
            "POST /v1/chat/completions HTTP/1.1\r\nAuthorization: Bearer secret\r\nContent-Length: 1000000\r\n\r\n".utf8
        )))
        XCTAssertEqual(head.contentLength, 1_000_000)
        XCTAssertEqual(head.request.headers["authorization"], "Bearer secret")
        XCTAssertNil(head.request.body)
    }

    func testEmbeddedImagesDecodeAcrossSupportedDialects() throws {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let encoded = png.base64EncodedString()
        let dataURL = "data:image/png;base64,\(encoded)"
        func json(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }
        let openAI = try LocalAPIChatRequest.decodeOpenAI(json([
            "model": "qwen", "messages": [["role": "user", "content": [
                ["type": "text", "text": "What is this?"],
                ["type": "image_url", "image_url": ["url": dataURL]]
            ]]]
        ]))
        let responses = try LocalAPIChatRequest.decodeOpenAIResponses(json([
            "model": "qwen", "input": [["role": "user", "content": [
                ["type": "input_image", "image_url": dataURL]
            ]]]
        ]))
        let ollama = try LocalAPIChatRequest.decodeOllamaChat(json([
            "model": "qwen", "messages": [["role": "user", "images": [encoded]]]
        ]))
        let generate = try LocalAPIChatRequest.decodeOllamaGenerate(json([
            "model": "qwen", "prompt": "Describe it", "images": [encoded]
        ]))
        let anthropic = try LocalAPIChatRequest.decodeAnthropic(json([
            "model": "qwen", "max_tokens": 32, "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": encoded]]
            ]]]
        ]))
        for request in [openAI, responses, ollama, generate, anthropic] {
            let imageMessage = try XCTUnwrap(request.messages.first { !$0.imageThumbnails.isEmpty })
            XCTAssertEqual(imageMessage.imageThumbnailData, png)
            XCTAssertEqual(imageMessage.imageThumbnails.count, 1)
        }
    }

    func testRemoteImageURLIsRejected() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "model": "qwen", "messages": [["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "https://example.com/image.png"]]
            ]]]
        ])
        XCTAssertThrowsError(try LocalAPIChatRequest.decodeOpenAI(data))
    }

    func testStrictToolSchemaChecksNestedValuesAndXMLParameters() throws {
        let schema = #"{"type":"object","required":["count","options"],"additionalProperties":false,"properties":{"count":{"type":"integer"},"options":{"type":"object","required":["enabled"],"properties":{"enabled":{"type":"boolean"}}}}}"#
        XCTAssertTrue(LocalAPIToolSchema.accepts(
            argumentsJSON: #"{"count":3,"options":{"enabled":true}}"#, schemaJSON: schema
        ))
        XCTAssertFalse(LocalAPIToolSchema.accepts(
            argumentsJSON: #"{"count":"three","options":{"enabled":true}}"#, schemaJSON: schema
        ))
        XCTAssertFalse(LocalAPIToolSchema.accepts(
            argumentsJSON: #"{"count":3,"options":{"enabled":true},"extra":1}"#, schemaJSON: schema
        ))
        XCTAssertFalse(LocalAPIToolSchema.accepts(
            argumentsJSON: #"{"count":3}"#,
            schemaJSON: #"{"type":"object","additionalProperties":false}"#
        ))
        let tool = LocalAPIToolDefinition(name: "count", description: nil, parametersJSON: schema)
        let xml = "<tool_call><function name=\"count\"><parameter name=\"count\">3</parameter><parameter name=\"options\">{\"enabled\":true}</parameter></function></tool_call>"
        let calls = LocalAPIToolCalling.parse(xml, tools: [tool], parallelToolCalls: false,
                                              validateSchemas: true)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.argumentsJSON, #"{"count":3,"options":{"enabled":true}}"#)
    }

    /// One peer's bad keys lock only that peer, and the lock expires.
    func testAuthThrottleLocksOnlyTheFailingHost() {
        var throttle = AuthFailureThrottle()
        let start = Date()
        for i in 0..<AuthFailureThrottle.maxFailures {
            XCTAssertFalse(throttle.isLocked("10.0.0.9", now: start))
            throttle.recordFailure("10.0.0.9", now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertTrue(throttle.isLocked("10.0.0.9", now: start.addingTimeInterval(5)))
        XCTAssertFalse(throttle.isLocked("10.0.0.2", now: start.addingTimeInterval(5)))
        XCTAssertFalse(throttle.isLocked("10.0.0.9", now: start.addingTimeInterval(5 + AuthFailureThrottle.lockout)))
    }
}
