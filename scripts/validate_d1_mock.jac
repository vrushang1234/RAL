"""D1 structural proof with MockLLM (no API key required)."""

import from jaclang.byllm.lib { MockLLM }

glob llm = MockLLM(model_name="mockllm", config={"outputs": [
    "Bonjour, comment allez-vous?",
    "HELLO, HOW ARE YOU?"
]});

def run_agent(role_description: str, instructions: str, input_json: str) -> str by llm();
sem run_agent = "Act according to the given role and follow the instructions to transform the input.";
sem run_agent.role_description = "The agent's fixed role. Always stay within this role.";
sem run_agent.instructions = "The task instructions to follow exactly.";
sem run_agent.input_json = "The input data to transform (JSON or plain text).";

with entry {
    a = run_agent("You are a helpful assistant.", "Respond in French.", "Hello, how are you?");
    b = run_agent("You are a helpful assistant.", "Respond in ALL UPPERCASE.", "Hello, how are you?");
    print("A:", a);
    print("B:", b);
    assert a != b;
    print("D1 MOCK PASS: two instruction strings produced two different outputs via prompt-as-parameter.");
}
