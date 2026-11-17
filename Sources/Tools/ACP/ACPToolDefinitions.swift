//
// Terrapin
// Copyright (C) 2026 Blue Turtle Corporation
// Author: David Gill
// ACPToolDefinitions.swift
//

import Stores

/// The model-facing tool schemas for the ACP client tools, plus the
/// shell-invocation constants the terminal tools re-express commands with.
extension ACPClientTools {
    // The description tracks the server's vision flag: when the server says
    // the model cannot see, the image claim is dropped so the model does not
    // attempt image reads it could never use.
    var readTextFileDefinition: ToolDefinition {
        let description = supportsVision == false
            ? "Reads a file from the client's file system, including unsaved editor changes. Text files are returned as text; the current model cannot view image files. For any project files, you MUST use this call."
            : "Reads a file from the client's file system, including unsaved editor changes. Text files are returned as text; image files (PNG, JPEG, GIF, WebP, TIFF, BMP, HEIC) are returned as images you can see. For any project files, you MUST use this call."
        return ToolDefinition(
            function: FunctionDefinition(
                name: "read_file",
                description: description,
                parameters: Self.readTextFileParameters
            )
        )
    }
    
    private static let readTextFileParameters: [String: AnySendable] = [
        "type": AnySendable("object"),
        "properties": AnySendable([
            "path": AnySendable([
                "type": AnySendable("string"),
                "description": AnySendable("Path of the file to read. Relative paths are resolved against the working directory.")
            ]),
            "line": AnySendable([
                "type": AnySendable("integer"),
                "description": AnySendable("Optional 1-based line number to start reading from.")
            ]),
            "limit": AnySendable([
                "type": AnySendable("integer"),
                "description": AnySendable("Optional maximum number of lines to read.")
            ])
        ]),
        "required": AnySendable([AnySendable("path")])
    ]
    
    static let writeTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "write_file",
            description: "Writes a complete file to the client's file system, creating any missing parent directories. For creating or overwriting any project files, you MUST use this call.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to write. Relative paths are resolved against the working directory.")
                    ]),
                    "content": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The full file content to write to the disk")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("content")])
            ]
        )
    )
    
    static let editTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "edit_file",
            description: "Edits a file by replacing one text block for another. Edits MUST match the old text identically, including whitespace and newlines.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to read. Relative paths are resolved against the working directory.")
                    ]),
                    "existingText": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The existing text of the file to replace.")
                    ]),
                    "newText": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The text to overwrite the existingText with.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("existingText"), AnySendable("newText")])
            ]
        )
    )
    
    static let grepTextFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "grep_file",
            description: "Searches workspace files for an extended regex pattern (e.g. 'foo|bar', 'func\\s+\\w+').",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "query": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The extended regex pattern to search for. Set isRegex to false to search for a literal string instead.")
                    ]),
                    "pathPattern": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Optional glob filter on file paths (e.g. '*.swift', 'Sources/*'). Patterns without '/' match the file name; patterns with '/' match the path relative to the workspace root. '*' does not cross directory boundaries; use '**' to match across directories.")
                    ]),
                    "caseSensitive": AnySendable([
                        "type": AnySendable("boolean"),
                        "description": AnySendable("Whether the search should be case sensitive. Defaults to false.")
                    ]),
                    "isRegex": AnySendable([
                        "type": AnySendable("boolean"),
                        "description": AnySendable("Whether to treat query as an extended regex pattern. Defaults to true. Set to false to search for a literal string.")
                    ])
                ]),
                "required": AnySendable([AnySendable("query")])
            ]
        )
    )
    
    static let moveFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "move_file",
            description: "Moves or renames a file to a new path within the workspace, creating any missing parent directories at the destination. The destination must not already exist.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to move. Relative paths are resolved against the working directory.")
                    ]),
                    "newPath": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("The new path for the file. Relative paths are resolved against the working directory.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path"), AnySendable("newPath")])
            ]
        )
    )
    
    static let deleteFileDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "delete_file",
            description: "Deletes a file from the client's file system. Destructive and irreversible: only use when the user explicitly asked to delete the file.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Path of the file to delete. Relative paths are resolved against the working directory.")
                    ])
                ]),
                "required": AnySendable([AnySendable("path")])
            ]
        )
    )
    
    static let listDirectoryDefinition = ToolDefinition(
        function: FunctionDefinition(
            name: "list_directory",
            description: "Lists the contents of a directory in the workspace, including file names and sizes.",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable([
                    "path": AnySendable([
                        "type": AnySendable("string"),
                        "description": AnySendable("Directory to list. Relative paths are resolved against the working directory. Defaults to the workspace root.")
                    ])
                ]),
                "required": AnySendable([AnySendable]())
            ]
        )
    )
    
    // The shell used to interpret full command lines (pipes, redirects,
    // multiple statements, ...) when the model puts them in `command`.
    #if os(Windows)
    static let shellCommand = "powershell.exe"
    static let shellArgs: [String] = ["-NoProfile", "-Command"]
    private static let shellInvocation = "powershell -Command"
    #else
    static let shellCommand = "/bin/sh"
    static let shellArgs: [String] = ["-c"]
    private static let shellInvocation = "/bin/sh -c"
    #endif

    // POSIX shell names (bare and absolute) the model may pass as `command`
    // while putting the intended command lines in `args` instead of using
    // the -c flag.
    static let posixShells: Set<String> = [
        "sh", "/bin/sh", "zsh", "/bin/zsh", "bash", "/bin/bash"
    ]

    static let terminalDefinitions: [ToolDefinition] = [
        ToolDefinition(
            function: FunctionDefinition(
                name: "run_command",
                description: "Runs a shell command in a client terminal, waits for it to finish, and returns the exit status and output. Prefer this over Xcode MCP tools for shell commands (git, swift, xcodebuild, scripts, ...).",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "command": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The program to execute, e.g. 'git' — not a full command line; put arguments in `args`. For shell pipelines, redirects, command substitution, or multiple statements, put the entire line here (e.g. 'git status | grep modified') and leave `args` empty; it is then run via \(ACPClientTools.shellInvocation).")
                        ]),
                        "args": AnySendable([
                            "type": AnySendable("array"),
                            "items": AnySendable(["type": AnySendable("string")]),
                            "description": AnySendable("Command arguments as separate strings, e.g. [\"status\", \"-s\"]. No shell metacharacters — for those, use a full line in `command`.")
                        ]),
                        "cwd": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("Optional absolute working directory. Defaults to the session working directory.")
                        ]),
                        "env": AnySendable([
                            "type": AnySendable("object"),
                            "description": AnySendable("Optional environment variables as a key/value map.")
                        ]),
                        "timeoutSeconds": AnySendable([
                            "type": AnySendable("integer"),
                            "description": AnySendable("Optional maximum time to wait, in seconds (default 120, max 600). The command is killed when it elapses.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("command")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_create",
                description: "Starts a command in a new client terminal and returns its terminalId. Use the other terminal tools with that id to observe, wait for, kill, or release it. Prefer run_command for one-shot commands.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "command": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The command to execute, e.g. 'swift'.")
                        ]),
                        "args": AnySendable([
                            "type": AnySendable("array"),
                            "items": AnySendable(["type": AnySendable("string")]),
                            "description": AnySendable("Command arguments as separate strings.")
                        ]),
                        "cwd": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("Optional absolute working directory. Defaults to the session working directory.")
                        ]),
                        "env": AnySendable([
                            "type": AnySendable("object"),
                            "description": AnySendable("Optional environment variables as a key/value map.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("command")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_output",
                description: "Retrieves the current output of a terminal without waiting for the command to finish.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_wait_for_exit",
                description: "Waits until the command in a terminal finishes and returns its exit status.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_kill",
                description: "Kills the command running in a terminal without releasing it.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        ),
        ToolDefinition(
            function: FunctionDefinition(
                name: "terminal_release",
                description: "Releases a terminal that is no longer needed. Always release terminals you created.",
                parameters: [
                    "type": AnySendable("object"),
                    "properties": AnySendable([
                        "terminalId": AnySendable([
                            "type": AnySendable("string"),
                            "description": AnySendable("The id returned by terminal_create.")
                        ])
                    ]),
                    "required": AnySendable([AnySendable("terminalId")])
                ]
            )
        )
    ]
}
