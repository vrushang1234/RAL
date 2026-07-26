"""TaskWalker: traverse FlowNode graph, execute byLLM / heuristics, record trace."""

import json;
import from .nodes { FlowNode, FlowEdge }
import from .llm { safe_run_agent, safe_run_router, RouteChoice }
import from .jsonpath { path_get, path_set }

walker TaskWalker {
    has initial_input: str = "";
    has all_node_ids: list = [];
    has nodes_by_id: dict = {};
    has visited_ids: list = [];
    has execution_trace: list = [];
    has step_counter: int = 0;
    has failed: bool = False;
    has final_output: str = "";
    has node_inputs: dict = {};
    has upstream_outputs: dict = {};

    can execute with FlowNode entry {
        if here.node_id in self.visited_ids {
            skip;
        }
        self.visited_ids = self.visited_ids + [here.node_id];

        input_received: dict = {"input": self.initial_input};
        if here.node_id in self.node_inputs {
            input_received = self.node_inputs[here.node_id] as dict;
        }

        if here.kind == "Trigger" {
            self._trace(here.node_id, "EXECUTED", input_received, json.dumps(input_received), "");
            self._push(here, input_received, "");
        } elif here.kind == "Router" {
            options: list = [];
            for e in [edge here -->] {
                if e.condition_type == "ROUTE_VALUE" and e.route_value != "" {
                    options = options + [e.route_value];
                }
            }
            prompt = "";
            if "system_prompt" in here.prompt_config {
                prompt = str(here.prompt_config["system_prompt"]);
            }
            try {
                choice: RouteChoice = safe_run_router(prompt, json.dumps(input_received), options);
                out = json.dumps({"route": choice.route, "reason": choice.reason});
                self._trace(here.node_id, "EXECUTED", input_received, out, "");
                self._push(here, input_received, choice.route);
            } except Exception as err {
                self._trace(here.node_id, "FAILED", input_received, "", str(err));
                self.failed = True;
                disengage;
            }
        } elif here.kind == "WorkerAgent" {
            prompt = "";
            if "system_prompt" in here.prompt_config {
                prompt = str(here.prompt_config["system_prompt"]);
            }
            try {
                out = safe_run_agent(here.fixed_role_description, prompt, json.dumps(input_received));
                self.upstream_outputs = {**self.upstream_outputs, here.node_id: out};
                self._trace(here.node_id, "EXECUTED", input_received, out, "");
                self._push(here, {"output": out, "node_id": here.node_id}, "");
            } except Exception as err {
                self._trace(here.node_id, "FAILED", input_received, "", str(err));
                self.failed = True;
                disengage;
            }
        } elif here.kind == "Aggregator" {
            agg_cfg: dict = {};
            if "aggregator" in here.type_config and here.type_config["aggregator"] {
                agg_cfg = here.type_config["aggregator"] as dict;
            }
            required_raw: list = [];
            if "required_upstream_node_ids" in agg_cfg and agg_cfg["required_upstream_node_ids"] {
                required_raw = agg_cfg["required_upstream_node_ids"] as list;
            }
            required: list = [];
            for r in required_raw {
                rid = str(r);
                if rid in self.visited_ids {
                    required = required + [rid];
                }
            }
            for rid in required {
                if rid not in self.upstream_outputs {
                    skip;
                }
            }
            prompt = "";
            if "system_prompt" in here.prompt_config {
                prompt = str(here.prompt_config["system_prompt"]);
            }
            try {
                out = safe_run_agent(
                    here.fixed_role_description,
                    prompt,
                    json.dumps(self.upstream_outputs)
                );
                self.final_output = out;
                self._trace(here.node_id, "EXECUTED", input_received, out, "");
            } except Exception as err {
                self._trace(here.node_id, "FAILED", input_received, "", str(err));
                self.failed = True;
                disengage;
            }
        }
    }

    def _trace(nid: str, status: str, inp: dict, out: str, err: str) {
        self.step_counter = self.step_counter + 1;
        self.execution_trace = self.execution_trace + [{
            "step": self.step_counter,
            "node_id": nid,
            "status": status,
            "input_received": json.dumps(inp),
            "output_generated": out,
            "error_message": err
        }];
    }

    def _push(from_node: FlowNode, payload: dict, only_route: str) {
        for e in [edge from_node -->] {
            follow = False;
            if e.condition_type == "ALWAYS" or e.condition_type == "ON_SUCCESS" {
                follow = True;
            } elif e.condition_type == "ROUTE_VALUE" and only_route != "" and e.route_value == only_route {
                follow = True;
            }
            if not follow {
                continue;
            }
            tgt_id = e.target_node_id;
            if tgt_id not in self.nodes_by_id {
                continue;
            }
            existing: dict = {};
            if tgt_id in self.node_inputs {
                existing = self.node_inputs[tgt_id] as dict;
            }
            ms: str = str(e.mapping_source);
            mt: str = str(e.mapping_target);
            mapped_val: any = path_get(payload, ms);
            updated = path_set(existing, mt, mapped_val);
            self.node_inputs = {**self.node_inputs, tgt_id: updated};
            tgt = self.nodes_by_id[tgt_id] as FlowNode;
            visit [tgt];
        }
    }
}
