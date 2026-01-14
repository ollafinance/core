declare module "solhint" {
    export const RuleTester: any;
}

declare module "solhint/lib/rules/base-checker" {
    class BaseChecker {
        constructor(reporter: unknown, ruleId: string, meta: unknown);
        error(node: unknown, message: string): void;
        warn(node: unknown, message: string): void;
    }

    export = BaseChecker;
}
