// Filled by `wrangler types` after resources exist.
// Hand-written until then so tsc can run without a Cloudflare login.

interface Workflow {
  create(options: { id?: string; params?: unknown }): Promise<{ id: string }>;
}

declare module "cloudflare:workers" {
  export class WorkflowEntrypoint<Env = unknown, Params = unknown> {
    constructor(ctx: ExecutionContext, env: Env);
    protected env: Env;
    protected ctx: ExecutionContext;
    run(event: WorkflowEvent<Params>, step: WorkflowStep): Promise<unknown>;
  }
  export interface WorkflowEvent<Params> {
    payload: Params;
    timestamp: Date;
    instanceId: string;
  }
  export interface WorkflowStep {
    do<T>(name: string, configOrFn: WorkflowStepConfig | (() => Promise<T>), fn?: () => Promise<T>): Promise<T>;
    sleep(name: string, duration: string | number): Promise<void>;
  }
  export interface WorkflowStepConfig {
    retries?: { limit: number; delay: string | number; backoff?: "exponential" | "linear" | "constant" };
    timeout?: string | number;
  }
}
