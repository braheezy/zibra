const std = @import("std");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const width = 800;
const height = 600;

pub const Browser = struct {
    window: *c.SDL_Window,
    canvas: *c.SDL_Renderer,

    pub fn init(al: std.mem.Allocator) !*Browser {
        // Initialize SDL
        if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
            c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        }

        // Create a window
        const screen = c.SDL_CreateWindow(
            "zibra",
            c.SDL_WINDOWPOS_UNDEFINED,
            c.SDL_WINDOWPOS_UNDEFINED,
            width,
            height,
            c.SDL_WINDOW_OPENGL,
        ) orelse
            {
            c.SDL_Log("Unable to create window: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        // Create a renderer, which will be used to draw to the window
        const renderer = c.SDL_CreateRenderer(screen, -1, c.SDL_RENDERER_ACCELERATED) orelse {
            c.SDL_Log("Unable to create renderer: %s", c.SDL_GetError());
            return error.SDLInitializationFailed;
        };

        var browser = try al.create(Browser);
        browser.window = screen;
        browser.canvas = renderer;

        return browser;
    }

    pub fn free(self: *Browser, al: std.mem.Allocator) void {
        c.SDL_DestroyRenderer(self.canvas);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        al.destroy(self);
    }

    pub fn run(self: *Browser) void {
        var quit = false;
        while (!quit) {
            var event: c.SDL_Event = undefined;
            // Handle events
            while (c.SDL_PollEvent(&event) != 0) {
                switch (event.type) {
                    // Quit when the window is closed
                    c.SDL_QUIT => {
                        quit = true;
                    },
                    else => {},
                }
            }
            // Clear canvas with white
            _ = c.SDL_SetRenderDrawColor(self.canvas, 255, 255, 255, 255);
            _ = c.SDL_RenderClear(self.canvas);

            // Render something on canvas (example: blue rectangle)
            _ = c.SDL_SetRenderDrawColor(self.canvas, 0, 0, 255, 255);
            const rect = c.SDL_Rect{ .x = 100, .y = 100, .w = 200, .h = 150 };
            _ = c.SDL_RenderFillRect(self.canvas, &rect);

            // Present the updated frame
            c.SDL_RenderPresent(self.canvas);

            // we delay for 17ms to get 60fps
            c.SDL_Delay(17);
        }
    }
};
