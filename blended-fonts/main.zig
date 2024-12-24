const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_ttf.h");
});

pub fn main() !void {
    // Initialize SDL2
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.log.err("SDL_Init Error: {s}", .{c.SDL_GetError()});
        return error.SDLInitFailed;
    }
    defer c.SDL_Quit();

    // Initialize SDL2_ttf
    if (c.TTF_Init() != 0) {
        std.log.err("TTF_Init Error: {s}", .{c.TTF_GetError()});
        return error.TTFInitFailed;
    }
    defer c.TTF_Quit();

    // Create SDL Window
    const window = c.SDL_CreateWindow(
        "Blended Text Test",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        800,
        600,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_ALLOW_HIGHDPI | c.SDL_WINDOW_OPENGL,
    ) orelse {
        std.log.err("SDL_CreateWindow Error: {s}", .{c.SDL_GetError()});
        return error.WindowCreationFailed;
    }
    defer c.SDL_DestroyWindow(window);

    // Create SDL Renderer
    const renderer = c.SDL_CreateRenderer(
        window,
        -1,
        c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
    );
    if (renderer == null) {
        std.log.err("SDL_CreateRenderer Error: {s}", .{c.SDL_GetError()});
        return error.RendererCreationFailed;
    }
    defer c.SDL_DestroyRenderer(renderer);

    // Load Font
    const font_path = "/usr/share/fonts/google-noto-emoji-fonts/NotoEmoji-Regular.ttf"; // Adjust for your system
    const font = c.TTF_OpenFont(font_path, 48) orelse {
        std.log.err("TTF_OpenFont Error: {s}", .{c.TTF_GetError()});
        return error.FontLoadFailed;
    }
    defer c.TTF_CloseFont(font);

    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255); // Set background to white
    _ = c.SDL_RenderClear(renderer);

    // Render Text with TTF_RenderUTF8_Blended
    const text = "😀";
    const text_color = c.SDL_Color{ .r = 0, .g = 0, .b = 0, .a = 255 }; // Normal color (black)

    const text_surface = c.TTF_RenderUTF8_Blended(font, text, text_color);
    if (text_surface == null) {
        std.log.err("TTF_RenderUTF8_Blended Error: {s}", .{c.TTF_GetError()});
        return error.TextRenderFailed;
    }
    defer c.SDL_FreeSurface(text_surface);

    const text_texture = c.SDL_CreateTextureFromSurface(renderer, text_surface);
    if (text_texture == null) {
        std.log.err("SDL_CreateTextureFromSurface Error: {s}", .{c.SDL_GetError()});
        return error.TextureCreationFailed;
    }
    defer c.SDL_DestroyTexture(text_texture);

    const dest_rect = c.SDL_Rect{
        .x = 100,
        .y = 100,
        .w = text_surface.*.w,
        .h = text_surface.*.h,
    };

    var quit = false;
    while (!quit) {
        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                // Quit when the window is closed
                c.SDL_QUIT => quit = true,
                else => {},
            }
        }

        // Clear canvas with white
        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
        _ = c.SDL_RenderClear(renderer);

        // Render the text texture
        _ = c.SDL_RenderCopy(renderer, text_texture, null, &dest_rect);
        c.SDL_RenderPresent(renderer);

        // delay for 17ms to get 60fps
        c.SDL_Delay(17);
    }
}
