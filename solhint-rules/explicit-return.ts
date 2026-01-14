const BaseChecker = require("solhint/lib/rules/base-checker");

type ASTNode = {
    type?: string;
    [key: string]: unknown;
};

const RULE_ID = "explicit-return";
const DEFAULT_MESSAGE = "Explicit return required for functions with named return variables.";

const meta = {
    type: "best-practices",
    docs: {
        description: "Require explicit return for named return variables.",
        category: "Best Practices Rules",
    },
    recommended: false,
};

type ReturnParameter = {
    name?: string;
    identifier?: { name?: string };
};

type ReturnParameterList = ReturnParameter[] | { parameters?: ReturnParameter[] };

interface FunctionDefinitionNode extends ASTNode {
    body?: ASTNode;
    returnParameters?: ReturnParameterList;
}

function extractReturnParameters(node: FunctionDefinitionNode): ReturnParameter[] {
    const params = node.returnParameters;
    if (!params) {
        return [];
    }
    if (Array.isArray(params)) {
        return params;
    }
    return params.parameters ?? [];
}

function hasNamedReturnParameters(node: FunctionDefinitionNode): boolean {
    const params = extractReturnParameters(node);
    if (params.length === 0) {
        return false;
    }
    return params.some((param) => Boolean(param.name ?? param.identifier?.name));
}

function hasReturnStatement(node?: ASTNode): boolean {
    if (!node) {
        return false;
    }
    if (node.type === "ReturnStatement") {
        return true;
    }

    for (const value of Object.values(node)) {
        if (Array.isArray(value)) {
            for (const child of value) {
                if (child && typeof child.type === "string" && hasReturnStatement(child)) {
                    return true;
                }
            }
        } else if (value && typeof value === "object" && typeof (value as ASTNode).type === "string") {
            if (hasReturnStatement(value as ASTNode)) {
                return true;
            }
        }
    }

    return false;
}

class ExplicitReturnChecker extends BaseChecker {
    constructor(reporter: unknown) {
        super(reporter, RULE_ID, meta);
    }

    FunctionDefinition(node: ASTNode) {
        const functionNode = node as FunctionDefinitionNode;
        if (!functionNode.body) {
            return;
        }
        if (!hasNamedReturnParameters(functionNode)) {
            return;
        }
        if (!hasReturnStatement(functionNode.body)) {
            this.error(node, DEFAULT_MESSAGE);
        }
    }
}

module.exports = ExplicitReturnChecker;
module.exports.RULE_ID = RULE_ID;
module.exports.DEFAULT_MESSAGE = DEFAULT_MESSAGE;

export {};
