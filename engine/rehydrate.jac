"""PromptRehydrator: apply RL mutations to prompt_config.system_prompt (D9)."""

import from .nodes { FlowNode }

walker PromptRehydrator {
    has mutations: dict = {};
    has applied: list = [];

    can apply with FlowNode entry {
        if here.node_id in self.applied {
            skip;
        }
        if here.node_id in self.mutations {
            new_prompt = str(self.mutations[here.node_id]);
            pc: dict = here.prompt_config;
            ver = 1;
            if "prompt_version" in pc {
                ver = int(pc["prompt_version"]) + 1;
            }
            here.prompt_config = {
                "prompt_id": pc["prompt_id"] if "prompt_id" in pc else "",
                "prompt_version": ver,
                "system_prompt": new_prompt,
                "user_prompt_template": pc["user_prompt_template"] if "user_prompt_template" in pc else "",
                "output_instructions": pc["output_instructions"] if "output_instructions" in pc else "",
                "variables": pc["variables"] if "variables" in pc else []
            };
            self.applied = self.applied + [here.node_id];
        }
        visit [-->];
    }
}
