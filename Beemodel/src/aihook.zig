// Where Tidy with AI (folder.s do_fd_tidy_ai) and the AI line-up of a
// reference set (refset.s do_refs_ai) hand their work to the AI Assistant
// (ai.s). The AI Assistant's module sets these when it starts; until then the
// operators say the assistant is not there (and send nothing).
const std = @import("std");
const app = @import("app.zig");

/// ai_send_as(shown, sent, note): the prompt the transcript shows, the text
/// sent, a note after it (or null). One undo step for what the AI does.
pub var send_as: ?*const fn (shown: []const u8, sent: []const u8, note: ?[]const u8) void = null;
/// ai_busy: a request is under way.
pub var busy: ?*const fn () bool = null;
/// find_editor(ED_AI), else wsp_ai: the AI Assistant in view.
pub var show: ?*const fn () void = null;

pub fn isBusy() bool {
    return if (busy) |f| f() else false;
}

/// Sends, or says the assistant is not there: true when it went.
pub fn send(shown: []const u8, sent: []const u8, note: ?[]const u8) bool {
    const f = send_as orelse {
        app.log("  the AI Assistant is not available", .{});
        return false;
    };
    f(shown, sent, note);
    return true;
}
