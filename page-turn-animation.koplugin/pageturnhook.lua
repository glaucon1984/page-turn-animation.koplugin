local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen
local Hook = {}

-- UIManager caches the public Screen.refresh* functions at module load, while
-- those functions still dispatch to refresh*Imp dynamically. Intercept the Imp
-- methods so a plugin loaded later can replace the physical repaint reliably.
local REFRESH_IMP_METHODS = {
    "refreshFullImp",
    "refreshPartialImp",
    "refreshNoMergePartialImp",
    "refreshFlashPartialImp",
    "refreshUIImp",
    "refreshNoMergeUIImp",
    "refreshFlashUIImp",
    "refreshFastImp",
    "refreshA2Imp",
}

-- A zero-delay task would be consumed by UIManager's due-task loop without
-- polling input. One millisecond is effectively immediate on an e-reader,
-- while still giving the event loop a chance to receive another tap.
local MIN_ASYNC_DELAY = 0.001

local function freeBuffer(bb)
    if bb then pcall(function() bb:free() end) end
end

local function restoreBuffer(screen, bb)
    local w, h = screen.bb:getWidth(), screen.bb:getHeight()
    screen.bb:blitFrom(bb, 0, 0, 0, 0, w, h)
end

local function clearArm(state)
    freeBuffer(state.old_bb)
    state.old_bb = nil
    state.direction = nil
    state.chapter_change = nil
    state.armed = false
end

local function isAnimationActive(state, animation)
    for _, candidate in ipairs(state.animations) do
        if candidate == animation then return true end
    end
    return false
end

local function cancelAnimations(state, reason)
    for _, animation in ipairs(state.animations) do
        animation.cancelled = true
        if animation.action then
            pcall(function() UIManager:unschedule(animation.action) end)
        end
        freeBuffer(animation.new)
        animation.new = nil
    end
    state.animations = {}
    state.latest_animation = nil
    state.chapter_full_refresh_pending = false
    state.markers = {}
    freeBuffer(state.base_bb)
    state.base_bb = nil

    if reason then
        logger.info("PageTurnAnimation: cancelled animation stack (" .. reason .. ")")
    end
end

local function decrementInterceptedRefresh()
    -- The refresh that started the page repaint was swallowed. Animation
    -- frames are direct Screen refreshes and do not belong to this counter.
    if UIManager.refresh_count and UIManager.refresh_count > 0 then
        UIManager.refresh_count = UIManager.refresh_count - 1
    end
end

-- Reveal steps are queued on the E-Ink controller asynchronously and can
-- still be in flight after the last one was submitted. The framebuffer only
-- waits for the most recent marker before a flashing update, which is not
-- enough with many steps: earlier strips may complete later than the last
-- one. Wait for every marker the animation submitted so the flash starts
-- after the animation visibly finished. Falls back to the last marker only
-- on devices without per-marker waits.
local function waitForAnimationUpdates(screen, markers)
    markers = markers or {}
    if type(screen.mech_wait_update_complete) == "function" then
        for i = 1, #markers - 1 do
            local marker = markers[i]
            if marker ~= screen.dont_wait_for_marker then
                pcall(screen.mech_wait_update_complete, screen, marker)
            end
        end
    end
    if screen.refreshWaitForLast then screen:refreshWaitForLast() end
end

local function settle(screen, config, markers)
    local w, h = screen.bb:getWidth(), screen.bb:getHeight()
    if config.full_refresh and screen.refreshFull then
        -- Strong cleanup option for aggressive waveforms such as A2. This is
        -- deliberately stronger than the normal AUTO/UI settle and may flash.
        waitForAnimationUpdates(screen, markers)
        screen:refreshFull(0, 0, w, h)
    elseif screen.refreshUI then
        -- Default behavior: one full-screen UI/AUTO settle after the reveal.
        screen:refreshUI(0, 0, w, h)
    elseif screen.refreshPartial then
        screen:refreshPartial(0, 0, w, h)
    end
    if screen.refreshWaitForLast then screen:refreshWaitForLast() end
end

local function submitRegion(state, waveform, x, y, w, h)
    if not x or not y or not w or not h or w <= 0 or h <= 0 then return end
    if waveform == "a2" then
        Screen:refreshA2(x, y, w, h)
    elseif waveform == "du" then
        Screen:refreshFast(x, y, w, h)
    else
        Screen:refreshUI(x, y, w, h)
    end
    -- mxcfb-style framebuffers expose the marker of the update just sent.
    local marker = Screen.marker
    if type(marker) == "number" and marker ~= state.markers[#state.markers] then
        state.markers[#state.markers + 1] = marker
    end
end

-- The first page turn owns the bottom of this stack. Every later page turn is
-- a new-page layer above it. Rendering from the bottom on every callback is
-- what allows an older turn to continue changing underneath a newer turn.
local function renderStack(state, Renderer)
    if not state.base_bb then return end

    restoreBuffer(Screen, state.base_bb)
    for _, animation in ipairs(state.animations) do
        if not animation.cancelled then
            Renderer.render(animation, Screen.bb)
        end
    end
end

-- A completed layer is a full page. It can become the new bottom layer and its
-- predecessor can be released, without changing the composited image.
local function collapseCompletedPrefix(state)
    while state.animations[1] and state.animations[1].done do
        local animation = table.remove(state.animations, 1)
        local old_base = state.base_bb
        state.base_bb = animation.new
        animation.new = nil
        freeBuffer(old_base)
    end
end

local function finishSequence(state)
    if #state.animations ~= 0 or not state.base_bb then return end

    local owner = state.owner
    local final_bb = state.base_bb
    local latest = state.latest_animation
    local config = latest and latest.config or {}
    local result = latest and latest.result or nil
    local settle_config = {
        full_refresh = config.full_refresh or state.chapter_full_refresh_pending or false,
    }
    local markers = state.markers
    state.markers = {}
    state.base_bb = nil
    state.latest_animation = nil
    state.chapter_full_refresh_pending = false
    state.suppress = false

    -- Async frames run outside UIManager's paint pass. Re-enter the framebuffer
    -- paint bracket so devices with per-paint rotation bookkeeping stay valid.
    state.bypass = true
    local ok, why = pcall(function()
        Screen:beforePaint()
        restoreBuffer(Screen, final_bb)
        settle(Screen, settle_config, markers)
        Screen:afterPaint()
    end)
    state.bypass = false

    if not ok then
        logger.warn("PageTurnAnimation: final settle failed:", why)
    end
    if owner and result then owner._last_page_turn_result = result end
    freeBuffer(final_bb)
end

local function abortAnimation(state, animation, reason)
    if not isAnimationActive(state, animation) then return end

    logger.warn("PageTurnAnimation: page-turn animation failed:", reason)

    -- Preserve the newest rendered page as a safe recovery target before the
    -- stack is released. This is preferable to leaving a partial composite in
    -- the framebuffer if a renderer or device call fails.
    local recovery
    if state.latest_animation and state.latest_animation.new then
        recovery = state.latest_animation.new:copy()
    elseif animation.new then
        recovery = animation.new:copy()
    end

    cancelAnimations(state, "renderer failure")
    clearArm(state)
    state.suppress = false

    if recovery then
        state.bypass = true
        local ok, why = pcall(function()
            Screen:beforePaint()
            restoreBuffer(Screen, recovery)
            settle(Screen, {})
            Screen:afterPaint()
        end)
        state.bypass = false
        if not ok then
            logger.warn("PageTurnAnimation: recovery settle failed:", why)
        end
        freeBuffer(recovery)
    end
end

local function scheduleAnimationStep(state, animation, delay)
    if not isAnimationActive(state, animation) or animation.cancelled then return end
    delay = tonumber(delay) or 0
    if delay < MIN_ASYNC_DELAY then delay = MIN_ASYNC_DELAY end
    UIManager:scheduleIn(delay, animation.action)
end

local function runAnimationStep(state, Renderer, animation)
    if not isAnimationActive(state, animation) or animation.cancelled then return end

    local frame
    state.bypass = true
    local bracket_ok, bracket_error = pcall(function()
        Screen:beforePaint()

        local ok, step_frame = pcall(Renderer.step, animation)
        if not ok then error(step_frame) end
        if type(step_frame) ~= "table" then
            error("renderer returned no frame state")
        end
        frame = step_frame

        renderStack(state, Renderer)
        if frame.dirty then
            submitRegion(
                state,
                animation.waveform,
                frame.dirty.x,
                frame.dirty.y,
                frame.dirty.w,
                frame.dirty.h
            )
        end

        Screen:afterPaint()
    end)
    state.bypass = false

    if not bracket_ok then
        abortAnimation(state, animation, bracket_error)
        return
    end
    if not isAnimationActive(state, animation) or animation.cancelled then return end

    if frame.done then
        animation.done = true
        animation.result = frame.result
        collapseCompletedPrefix(state)

        if #state.animations == 0 then
            finishSequence(state)
        end
    else
        scheduleAnimationStep(state, animation, frame.delay)
    end
end

-- Chapter membership of a page, as KOReader's own chapter navigation sees it:
-- the index of the ToC entry in effect on that page, skipping ToC depths the
-- user hid from the chapter markers. Any failure is treated as "unknown".
local function tocIndexForPage(toc, pageno)
    if type(pageno) ~= "number" then return nil end
    local ok, index = pcall(toc.getTocIndexByPage, toc, pageno, true)
    if ok then return index end
    logger.dbg("PageTurnAnimation: ToC lookup failed for page", pageno, index)
    return nil
end

-- True when a one-page turn from `before` to `after` crosses a ToC boundary in
-- either direction. Documents without a ToC never report a chapter change.
local function isChapterChange(owner, before, after)
    local toc = owner.ui and owner.ui.toc
    if not toc or type(toc.getTocIndexByPage) ~= "function" then return false end
    return tocIndexForPage(toc, before) ~= tocIndexForPage(toc, after)
end

function Hook.augment(PageTurnAnimation, Renderer)
    local state = Screen._pageturnanimation_page_turn_hook
    if not state then
        state = {
            originals = {},
            owner = nil,
            -- A first turn's old page becomes the stack base. Later turns only
            -- need their new-page buffers, which keeps overlap compositing
            -- cheaper than keeping one old snapshot per animation.
            base_bb = nil,
            old_bb = nil,
            direction = nil,
            -- Set while armed when the pending turn lands in another chapter.
            chapter_change = nil,
            -- Set once such a turn has been intercepted, until the whole
            -- animation stack settles or is cancelled.
            chapter_full_refresh_pending = false,
            -- Markers of the reveal updates submitted by the current stack.
            markers = {},
            armed = false,
            -- Suppresses the rest of the original repaint's refresh queue.
            -- It is cleared by afterPaint; animation callbacks use bypass.
            suppress = false,
            bypass = false,
            animations = {},
            latest_animation = nil,
        }
        Screen._pageturnanimation_page_turn_hook = state

        state.original_beforePaint = Screen.beforePaint
        Screen.beforePaint = function(screen, ...)
            local first_paint = not screen.painting
            local owner = state.owner
            local enabled = owner and (owner.auto_page_turn or owner._pageturnanimation_force_once)
            if first_paint and not state.bypass and enabled and owner._pageturnanimation_pending_direction then
                -- With no active stack, save the currently visible page as the
                -- bottom layer. With an active stack, its base and layers are
                -- already the authoritative current composite; do not snapshot
                -- or cancel them.
                clearArm(state)
                if #state.animations == 0 then
                    state.old_bb = screen.bb:copy()
                end
                state.direction = owner._pageturnanimation_pending_direction
                state.chapter_change = owner._pageturnanimation_pending_chapter_change == true
                owner._pageturnanimation_pending_direction = nil
                owner._pageturnanimation_pending_chapter_change = nil
                owner._pageturnanimation_force_once = nil
                state.armed = true
                state.suppress = false
                logger.info("PageTurnAnimation: armed reveal, direction", state.direction,
                    "chapter change", state.chapter_change,
                    "active layers", #state.animations)
            end
            return state.original_beforePaint(screen, ...)
        end

        state.original_afterPaint = Screen.afterPaint
        Screen.afterPaint = function(screen, ...)
            local result = state.original_afterPaint(screen, ...)
            if state.bypass then return result end

            -- A paint with no physical refresh means the page turn was not
            -- intercepted. Existing animation layers must not continue drawing
            -- over that unrelated framebuffer contents.
            if state.armed then
                local had_active_layers = #state.animations > 0
                clearArm(state)
                if had_active_layers then
                    cancelAnimations(state, "page repaint was not intercepted")
                end
            end
            state.suppress = false
            return result
        end

        local function interceptRefreshImp(name, original)
            return function(screen, ...)
                if state.bypass then return original(screen, ...) end

                -- Once the first refresh of a painted page has been consumed,
                -- discard any other refreshes in that same KOReader repaint.
                if state.suppress then return end

                local has_active_layers = #state.animations > 0
                if not state.armed or (not state.old_bb and not has_active_layers) then
                    -- A dialog or unrelated UI repaint should not be painted on
                    -- top of a moving page. Let it through, but abandon the
                    -- transition because its framebuffer is no longer ours.
                    if has_active_layers then
                        cancelAnimations(state, "external repaint")
                    end
                    return original(screen, ...)
                end

                local owner = state.owner
                if not owner then
                    clearArm(state)
                    return original(screen, ...)
                end

                local config = owner:getPageTurnConfig()
                local ready, why = Renderer.preflight(config)
                if not ready then
                    logger.warn("PageTurnAnimation: page-turn preflight failed:", why)
                    clearArm(state)
                    if has_active_layers then
                        cancelAnimations(state, "page-turn preflight failed")
                    end
                    return original(screen, ...)
                end

                local old_bb = state.old_bb
                local new_bb = screen.bb:copy()
                local direction = state.direction or 1
                local chapter_change = state.chapter_change == true
                state.old_bb = nil
                state.direction = nil
                state.chapter_change = nil
                state.armed = false
                state.suppress = true

                logger.info("PageTurnAnimation: intercepted repaint via", name,
                    "direction", direction, "shape", config.shape,
                    "waveform", config.waveform, "scheduler", config.scheduler,
                    "delay_ms", config.delay_ms, "full_refresh", config.full_refresh,
                    "chapter_mode", config.chapter_mode,
                    "chapter change", chapter_change,
                    "previous layers", #state.animations)

                -- The renderer now produces one overlay layer. The stack owns
                -- old_bb only for the first turn; later turns start above the
                -- existing composite and therefore do not need an old snapshot.
                local ok, animation, start_error = pcall(
                    Renderer.start,
                    nil,
                    new_bb,
                    direction,
                    config
                )
                if not ok or not animation then
                    local why_start = not ok and animation or start_error or "renderer returned no animation"
                    logger.warn("PageTurnAnimation: could not start animation:", why_start)
                    state.suppress = false
                    freeBuffer(old_bb)
                    freeBuffer(new_bb)
                    if has_active_layers then
                        cancelAnimations(state, "new layer could not start")
                    end
                    return original(screen, ...)
                end

                if not state.base_bb then
                    state.base_bb = old_bb
                    old_bb = nil
                end
                freeBuffer(old_bb)

                animation.config = config
                animation.done = false
                state.animations[#state.animations + 1] = animation
                state.latest_animation = animation
                if chapter_change then
                    -- Remembered on the stack, not the layer: a quick second
                    -- turn stacked on top must not lose the chapter cleanup.
                    state.chapter_full_refresh_pending = true
                end

                -- The original paint has put the destination page in RAM. Put
                -- the composited old/current layers back until the new layer's
                -- first scheduled frame is ready.
                renderStack(state, Renderer)
                decrementInterceptedRefresh()

                animation.action = function()
                    runAnimationStep(state, Renderer, animation)
                end
                -- nextTick preserves the existing first-frame timing while
                -- ensuring the original paint pass can finish cleanly first.
                UIManager:nextTick(animation.action)
                return
            end
        end

        for _, name in ipairs(REFRESH_IMP_METHODS) do
            local original = Screen[name]
            if type(original) == "function" then
                state.originals[name] = original
                Screen[name] = interceptRefreshImp(name, original)
            end
        end
    end

    local function installNavigationHook(owner, nav)
        if not nav or nav._pageturnanimation_direction_hook then return end
        local original = nav.onGotoViewRel
        if type(original) ~= "function" then return end
        nav._pageturnanimation_direction_hook = original

        nav.onGotoViewRel = function(nav_self, diff, no_page_turn)
            local step = tonumber(diff)
            local enabled = owner.auto_page_turn or owner._pageturnanimation_force_once
            local eligible = enabled and no_page_turn ~= true and (step == 1 or step == -1)

            local before = nav_self.current_page
            if eligible then
                local direction = step
                local view = owner.ui and owner.ui.view
                if view and view.inverse_reading_order then direction = -direction end
                owner._pageturnanimation_pending_direction = direction
            end

            local result = original(nav_self, diff, no_page_turn)
            local after = nav_self.current_page
            owner._pageturnanimation_pending_chapter_change = nil
            if eligible and before ~= nil and after ~= nil and before == after then
                owner._pageturnanimation_pending_direction = nil
                owner._pageturnanimation_force_once = nil
            elseif eligible and owner.chapter_mode ~= "animate" and owner.chapter_mode ~= nil then
                -- Only consulted when a chapter mode is on: the ToC lookup is
                -- cheap but not free, and it would be wasted otherwise.
                if isChapterChange(owner, before, after) then
                    if owner.chapter_mode == "flash" then
                        -- No animation at all: leave the repaint alone so it
                        -- reaches the panel untouched, and promote it to a
                        -- flashing full refresh exactly like KOReader's own
                        -- chapter-boundary flash does.
                        owner._pageturnanimation_pending_direction = nil
                        owner._pageturnanimation_force_once = nil
                        logger.info("PageTurnAnimation: chapter boundary, flashing instead of animating")
                        UIManager:setDirty(nil, "full")
                    else
                        owner._pageturnanimation_pending_chapter_change = true
                    end
                end
            end
            return result
        end
    end

    local old_init = PageTurnAnimation.init
    function PageTurnAnimation:init()
        old_init(self)
        cancelAnimations(state, "new document")
        clearArm(state)
        state.suppress = false
        state.owner = self
        installNavigationHook(self, self.ui and self.ui.paging)
        installNavigationHook(self, self.ui and self.ui.rolling)
        UIManager:nextTick(function()
            if state.owner == self and self.ui then
                installNavigationHook(self, self.ui.paging)
                installNavigationHook(self, self.ui and self.ui.rolling)
            end
        end)
    end

    local old_close = PageTurnAnimation.onCloseDocument
    function PageTurnAnimation:onCloseDocument(...)
        self._pageturnanimation_pending_direction = nil
        self._pageturnanimation_pending_chapter_change = nil
        self._pageturnanimation_force_once = nil
        if state.owner == self then
            cancelAnimations(state, "document closed")
            state.owner = nil
            clearArm(state)
            state.suppress = false
            state.bypass = false
        end
        if old_close then return old_close(self, ...) end
    end
end

return Hook
