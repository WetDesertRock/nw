
--native widgets - cococa backend.
--Written by Cosmin Apreutesei. Public domain.

local ffi = require'ffi'
local bit = require'bit'
local glue = require'glue'
local box2d = require'box2d'
local objc = require'objc'
local cbframe = require'cbframe'

local _cbframe = objc.debug.cbframe
objc.debug.cbframe = true --use cbframe for struct-by-val overrides.
objc.load'Foundation'
objc.load'AppKit'
objc.load'Carbon.HIToolbox' --for key codes
objc.load'ApplicationServices.CoreGraphics'
--objc.load'CoreGraphics' --for CGWindow*
objc.load'CoreFoundation' --for CFArray

local nw = {name = 'cocoa'}

--helpers --------------------------------------------------------------------

local function unpack_nsrect(r)
	return r.origin.x, r.origin.y, r.size.width, r.size.height
end

local function override_rect(x, y, w, h, x1, y1, w1, h1)
	return x1 or x, y1 or y, w1 or w, h1 or h
end

local function primary_screen_h()
	return objc.NSScreen:screens():objectAtIndex(0):frame().size.height
end

--convert rect from bottom-up relative-to-main-screen space to top-down relative-to-main-screen space
local function flip_screen_rect(main_h, x, y, w, h)
	main_h = main_h or primary_screen_h()
	return x, main_h - h - y, w, h
end

--os version -----------------------------------------------------------------

function nw:os()
	local s = objc.tolua(objc.NSProcessInfo:processInfo():operatingSystemVersionString()) --OSX 10.2+
	return 'OSX '..(s:match'%d+%.%d+%.%d+')
end

--app object -----------------------------------------------------------------

local app = {}
nw.app = app

local App = objc.class('App', 'NSApplication <NSApplicationDelegate>')

function app:new(frontend)

	self = glue.inherit({frontend = frontend}, self)

	--create the default autorelease pool for small objects.
	self.pool = objc.NSAutoreleasePool:new()

	--NOTE: we have to reference mainScreen() before using any of the
	--display functions, or we will get NSRecursiveLock errors.
	objc.NSScreen:mainScreen()

	self.nsapp = App:sharedApplication()
	self.nsapp.frontend = frontend
	self.nsapp.backend = self

	self.nsapp:setDelegate(self.nsapp)

	--set it to be a normal app with dock and menu bar.
	self.nsapp:setActivationPolicy(objc.NSApplicationActivationPolicyRegular)

	--disable mouse coalescing so that mouse move events are not skipped.
	objc.NSEvent:setMouseCoalescingEnabled(false)

	--the menubar must be initialized _before_ the app is activated.
	self:_init_menubar()

	--activate the app before windows are created.
	self:activate()

	return self
end

--message loop ---------------------------------------------------------------

function app:run()
	self.nsapp:run()
end

function app:stop()
	self.nsapp:stop(nil)
	--post a dummy event to ensure the stopping
	local event = objc.NSEvent:
		otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2(
			objc.NSApplicationDefined, objc.NSMakePoint(0,0), 0, 0, 0, nil, 1, 1, 1)
	self.nsapp:postEvent_atStart(event, true)
end

--quitting -------------------------------------------------------------------

--NOTE: quitting the app from the app's Dock menu calls appShouldTerminate, then calls close()
--on all windows, thus without calling windowShouldClose(), but only windowWillClose().
--NOTE: there's no windowDidClose() event and so windowDidResignKey() comes after windowWillClose().
--NOTE: applicationWillTerminate() is never called.

function App:applicationShouldTerminate()
	self.frontend:_backend_quitting() --calls quit() which calls stop().
	--we never terminate the app, we just stop the loop instead.
	return false
end

--timers ---------------------------------------------------------------------

objc.addmethod('App', 'nw_timerEvent', function(self, timer)
	if not timer.nw_func then return end
	if timer.nw_func() == false then
		timer:invalidate()
		timer.nw_func = nil
	end
end, 'v@:@')

function app:runevery(seconds, func)
	local timer = objc.NSTimer:scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
		seconds, self.nsapp, 'nw_timerEvent', nil, true)
	objc.NSRunLoop:currentRunLoop():addTimer_forMode(timer, objc.NSDefaultRunLoopMode)
	timer.nw_func = func
end

--windows --------------------------------------------------------------------

local window = {}
app.window = window

local nswin_map = {} --nswin->window

local Window = objc.class('Window', 'NSWindow <NSWindowDelegate, NSDraggingDestination>')

local cascadePoint

function window:new(app, frontend, t)
	self = glue.inherit({app = app, frontend = frontend}, self)

	local toolbox = t.frame == 'toolbox'
	local framed = t.frame == 'normal' or toolbox

	--compute initial window style.
	local style
	if framed then
		style = bit.bor(
			objc.NSTitledWindowMask,
			t.closeable and objc.NSClosableWindowMask or 0,
			not toolbox and t.minimizable and objc.NSMiniaturizableWindowMask or 0,
			t.resizeable and objc.NSResizableWindowMask or 0)
	else
		style = objc.NSBorderlessWindowMask
		--for frameless windows we have to handle maximization manually.
		self._frameless = true
	end

	--convert frame rect to client rect.
	local frame_rect = objc.NSMakeRect(flip_screen_rect(nil, t.x or 0, t.y or 0, t.w, t.h))
	local content_rect = objc.NSWindow:contentRectForFrameRect_styleMask(frame_rect, style)

	--create window (windows are created hidden).
	self.nswin = Window:alloc():initWithContentRect_styleMask_backing_defer(
							content_rect, style, objc.NSBackingStoreBuffered, false)

	--we have to own the window because we use luavars.
	self.nswin:setReleasedWhenClosed(false)

	--fix bug with minaturize()/close()/makeKeyAndOrderFront() sequence
	--which makes hovering on titlebar buttons not working.
	self.nswin:setOneShot(true)

	--if position is not given, cascade window, to emulate Windows behavior.
	if not t.x and not t.y then
		cascadePoint = cascadePoint or objc.NSMakePoint(10, 20)
		cascadePoint = self.nswin:cascadeTopLeftFromPoint(cascadePoint)
	end

	--set transparent.
	if t.transparent then
		self.nswin:setOpaque(false)
		self.nswin:setBackgroundColor(objc.NSColor:clearColor())
		--TODO: click-through option for transparent windows?
		--NOTE: in windows this is done with window.transparent (WS_EX_TRANSPARENT) attribute.
		--self.nswin:setIgnoresMouseEvents(true) --make it click-through
	end

	--set parent.
	if t.parent then
		t.parent.backend.nswin:addChildWindow_ordered(self.nswin, objc.NSWindowAbove)
	end

	--enable moving events.
	self._disabled = not t.enabled
	self._edgesnapping = t.edgesnapping
	self:_set_movable()

	--enable full screen button.
	if not toolbox and t.fullscreenable and nw.frontend:os'OSX 10.7' then
		self.nswin:setCollectionBehavior(bit.bor(tonumber(self.nswin:collectionBehavior()),
			objc.NSWindowCollectionBehaviorFullScreenPrimary)) --OSX 10.7+
	end

	--disable or hide the maximize and minimize buttons.
	if toolbox or (not t.maximizable and not t.minimizable) then
		--hide the minimize and maximize buttons when they're both disabled
		--or if toolbox frame, to emulate Windows behavior.
		self.nswin:standardWindowButton(objc.NSWindowZoomButton):setHidden(true)
		self.nswin:standardWindowButton(objc.NSWindowMiniaturizeButton):setHidden(true)
	else
		if not t.minimizable then
			self.nswin:standardWindowButton(objc.NSWindowMiniaturizeButton):setHidden(true)
		end
		if not t.maximizable then
			self.nswin:standardWindowButton(objc.NSWindowZoomButton):setEnabled(false)
		end
	end

	--set the title.
	self.nswin:setTitle(t.title)

	--init keyboard API.
	self.nswin:reset_keystate()

	--init drawable content view.
	self:_init_content_view()

	--enable mouse enter/leave events on the newly set content view.
	local opts = bit.bor(
		objc.NSTrackingActiveAlways,           --also when inactive (emulate Windows behavior)
		objc.NSTrackingInVisibleRect,          --only if unobscured (duh)
		objc.NSTrackingEnabledDuringMouseDrag, --also when dragging *into* the window
		objc.NSTrackingMouseEnteredAndExited,
		objc.NSTrackingMouseMoved,
		objc.NSTrackingCursorUpdate) --TODO: fix this with NSTrackingActiveAlways
	local rect = self.nswin:contentView():bounds()
	local area = objc.NSTrackingArea:alloc():initWithRect_options_owner_userInfo(
		rect, opts, self.nswin:contentView(), nil)
	self.nswin:contentView():addTrackingArea(area)

	--set constraints.
	if t.min_cw or t.min_ch then
		self:set_minsize(t.min_cw, t.min_ch)
	end
	if t.max_cw or t.max_ch then
		self:set_maxsize(t.max_cw, t.max_ch)
	end

	--set maximized state after setting constraints.
	if t.maximized then
		self:_maximize_frame()
	end

	--set topmost.
	if t.topmost then
		self:set_topmost(true)
	end

	--init drag & drop operation.
	self:_init_drop()

	--set visible state.
	self._visible = false

	--set minimized state
	self._minimized = t.minimized

	--set back references.
	self.nswin.frontend = frontend
	self.nswin.backend = self
	self.nswin.app = app

	--register window.
	nswin_map[objc.nptr(self.nswin)] = self.frontend

	--enable events.
	self.nswin:setDelegate(self.nswin)

	return self
end

--closing --------------------------------------------------------------------

--NOTE: close() doesn't call windowShouldClose.
function window:forceclose()
	self._closing = true
	self._hiding = nil
	self.nswin:close()
	--if it was hidden (i.e. already closed), there was no closing event.
	if self._closing then
		self.nswin:windowWillClose(nil)
	end
end

function Window:windowShouldClose()
	return self.frontend:_backend_closing() or false
end

function Window:windowWillClose()
	self.backend._closing = nil

	if self.backend._hiding then
		self.backend:_hidden()
		return
	end

	--force-close child windows first to emulate Windows behavior.
	if self:childWindows() then
		for i,win in objc.ipairs(self:childWindows()) do
			win:close(true)
		end
	end

	if self.backend:active() then
		--fake deactivation now because having close() not be async is more important.
		--TODO: win:active() and app:active_window() are not consistent with this event.
		self.frontend:_backend_deactivated()
	end

	self.frontend:_backend_closed()
	self.backend:_free_bitmap()

	nswin_map[objc.nptr(self)] = nil --unregister
	self:setDelegate(nil) --ignore further events

	--release the view manually.
	self.backend.nsview:release()
	self.backend.nsview = nil

	--release the window manually.
	--NOTE: we must release the nswin reference, not self, because self
	--is a weak reference and we can't release weak references.
	--NOTE: this will free all luavars.
	self.backend.nswin:release()
	self.backend.nswin = nil
end

--activation -----------------------------------------------------------------

--NOTE: windows created after calling activateIgnoringOtherApps(false) go behind the active app.
--NOTE: windows created after calling activateIgnoringOtherApps(true) go in front of the active app.
--NOTE: the first call to nsapp:activateIgnoringOtherApps() doesn't also activate the main menu.
--but NSRunningApplication:currentApplication():activateWithOptions() does, so we use that instead!
function app:activate()
	objc.NSRunningApplication:currentApplication():activateWithOptions(bit.bor(
			objc.NSApplicationActivateIgnoringOtherApps,
			objc.NSApplicationActivateAllWindows))
end

--NOTE: keyWindow() only returns the active window if the app itself is active.
function app:active_window()
	return nswin_map[objc.nptr(self.nsapp:keyWindow())]
end

function app:active()
	return self.nsapp:isActive()
end

function App:applicationWillBecomeActive()
	self.frontend:_backend_activated()
end

--NOTE: applicationDidResignActive() is not sent on exit because the loop will be stopped at that time.
function App:applicationDidResignActive()
	self.frontend:_backend_deactivated()
end

function Window:windowDidBecomeKey()
	if self.backend._entering_fs then
		self.backend._entering_fs = nil
		self.backend:_enter_fullscreen()
	end
	self:reset_keystate()
	self.frontend:_backend_activated()
end

function Window:windowDidResignKey()
	self.dragging = false
	self:reset_keystate()
	self.frontend:_backend_deactivated()
end

--NOTE: makeKeyAndOrderFront() on an initially hidden window is ignored, but not on an orderOut() window.
--NOTE: makeKeyWindow() and makeKeyAndOrderFront() do the same thing (both bring the window to front).
--NOTE: makeKeyAndOrderFront() is deferred, if the app is not active, for when it becomes active.
--Only windows activated while the app is inactive will move to front when the app is activated,
--but other windows will not, unlike clicking the dock icon, which moves all the app's window in front.
--So only the windows made key after the call to activateIgnoringOtherApps(true) are moved to front!
--NOTE: makeKeyAndOrderFront() is deferred to after the message loop is started,
--after which a single windowDidBecomeKey is triggered on the last window made key,
--unlike Windows which activates/deactivates windows as it happens, without a message loop.
function window:activate()
	self.nswin:makeKeyAndOrderFront(nil) --NOTE: async operation and can fail
end

function window:active()
	return self.nswin:isKeyWindow()
end

--NOTE: by default, windows with NSBorderlessWindowMask can't become key.
function Window:canBecomeKeyWindow()
	if not self.frontend or self.frontend:dead() then return true end --this is NOT a delegate method!
	return self.frontend:activable()
end

--NOTE: by default, windows with NSBorderlessWindowMask can't become main.
function Window:canBecomeMainWindow()
	if not self.frontend or self.frontend:dead() then return true end --this is NOT a delegate method!
	return self.frontend:activable()
end

--state/app visibility -------------------------------------------------------

function app:hidden()
	return self.nsapp:isHidden()
end

function app:unhide() --NOTE: async operation
	self.nsapp:unhide()
end

function app:hide() --NOTE: async operation
	self.nsapp:hide(nil)
end

function App:applicationDidUnhide()
	self.frontend:_backend_did_unhide()
end

function App:applicationDidHide()
	self.frontend:_backend_did_hide()
end

--state/visibility -----------------------------------------------------------

--NOTE: isVisible() returns false when the window is minimized.
--NOTE: isVisible() returns false when the app is hidden.
function window:visible()
	return self._visible
end

function window:show()
	if self._visible then return end
	if self._minimized then
		--was minimized before hiding, minimize it back.
		--TODO: does this activate the window? in Linux and Windows it does not.
		self.nswin:miniaturize(nil)
		--windowDidMiniaturize() is not called from hidden.
		self:_did_minimize()
	else
		self._visible = true
		--TODO: we need/assume that orderFront() is blocking. confirm that it is.
		self.nswin:orderFront(nil)
		self.frontend:_backend_changed()
		self.nswin:makeKeyWindow() --NOTE: async operation
	end
end

--NOTE: orderOut() is ignored on a minimized window (known bug from 2008).
--NOTE: orderOut() is buggy: calling it before starting the message loop
--results in a window that is not hidden and doesn't respond to mouse events.
function window:hide()
	if not self._visible then return end
	self._minimized = self.nswin:isMiniaturized()
	self._hiding = true
	self.nswin:close()
end

function window:_hidden()
	self._hiding = nil
	self._visible = false
	self.frontend:_backend_was_hidden()
end

--state/minimizing -----------------------------------------------------------

--NOTE: isMiniaturized() returns false on a hidden window.
function window:minimized()
	if self._minimized ~= nil then
		return self._minimized
	end
	return self.nswin:isMiniaturized()
end

--NOTE: miniaturize() in fullscreen mode is ignored.
--NOTE: miniaturize() shows the window if hidden.
function window:minimize()
	--TODO: does this activate the window? in Linux and Windows it does not.
	self.nswin:miniaturize(nil)
	--windowDidMiniaturize() is not called from hidden.
	if not self._visible then
		self.frontend:_backend_was_shown()
		self:_did_minimize()
	end
end

--NOTE: deminiaturize() shows the window if it's hidden.
function window:_unminimize()
	self.nswin:deminiaturize(nil)
	--windowDidDeminiaturize() is not called from hidden.
	if not self._visible then
		self.frontend:_backend_was_shown()
		self:_did_minimize()
	end
end

function window:_did_minimize()
	self._visible = true
	self._minimized = nil
	self.frontend:_backend_changed()
end

--NOTE: windowDidMiniaturize() is not called if minimizing from hidden state.
function Window:windowDidMiniaturize()
	self.frontend:_backend_was_unminimized()
	self.backend:_did_minimize()
end

--NOTE: windowDidDeminiaturize() is not called if restoring from hidden state.
function Window:windowDidDeminiaturize()
	self.frontend:_backend_was_minimized()
	self.backend:_did_minimize()
end

--state/maximizing -----------------------------------------------------------

--NOTE: isZoomed() returns true for frameless windows.
--NOTE: isZoomed() returns true while in fullscreen mode.
--NOTE: isZoomed() calls windowWillResize_toSize(), believe it!
function window:maximized()
	if self._maximized ~= nil then
		return self._maximized
	elseif self._frameless then
		return self:_maximized_frame()
	else
		self.nswin.nw_zoomquery = true --nw_resizing() barrier
		local zoomed = self.nswin:isZoomed()
		self.nswin.nw_zoomquery = false
		return zoomed
	end
end

local function near(a, b)
	return math.abs(a - b) < 10 --empirically found in OSX 10.9
end

--approximate the algorithm for isZoomed() for frameless windows.
function window:_maximized_frame()
	local screen = self.nswin:screen()
	if not screen then return false end --off-screen window
	local sx, sy, sw, sh = unpack_nsrect(screen:visibleFrame())
	local fx, fy, fw, fh = unpack_nsrect(self.nswin:frame())
	local csw, csh = self:_constrain_size(sw, sh)
	if csw < sw or csh < sh then
		--constrained: size must match max. size
		return near(fw, csw)
			and near(fh, csh)
	else
		--unconstrained: position and size must match screen rect
		return near(sx, fx)
			and near(sy, fy)
			and near(sx + sw, fx + fw)
			and near(sy + sh, fy + fh)
	end
end

--NOTE: zoom() on a minimized window is ignored.
--NOTE: zoom() on a fullscreen window is ignored.
--NOTE: zoom() on a frameless window is ignored.
--NOTE: zoom() on a hidden window works, and keeps the window hidden.

--NOTE: screen() on an initially hidden window works.
--NOTE: screen() on an orderOut() window is nil but on a closed window works!
--NOTE: screen() on a minimized window works!
--NOTE: screen() on an off-screen window is nil.

--maximize the window frame manually for when zoom() doesn't work.
--NOTE: off-screen windows maximize to the active screen.
--NOTE: hiding via orderOut() would make maximizing from hidden move the
--window to the active screen instead of the screen that matches the window's
--frame rect. Hiding via close() doesn't have this problem.
function window:_save_restore_frame()
	self._restore_frame = self.nswin:frame()
end
function window:_maximize_frame_manually()
	self:_save_restore_frame()
	local screen = self.nswin:screen() or objc.NSScreen:mainScreen()
	self.nswin:setFrame_display(screen:visibleFrame(), true)
	self:_apply_constraints()
end

--unmaximize the window frame manually for when zoom() doesn't work.
function window:_unmaximize_frame_manually()
	self.nswin:setFrame_display(self._restore_frame, true)
	self._restore_frame = nil
	self:_apply_constraints()
end

--maximize the window frame without changing its visibility.
--NOTE: frameless off-screen windows maximize to the active screen.
function window:_maximize_frame()
	if self._frameless then
		self:_maximize_frame_manually()
	else
		self.nswin:zoom(nil)
		self:_apply_constraints()
	end
end

--unmaximize the window manually to the saved rect.
function window:_unmaximize_frame()
	if self._frameless then
		self:_unmaximize_frame_manually()
	else
		self.nswin:zoom(nil)
		self:_apply_constraints()
	end
end

--zoom() doesn't work on a minimzied window, so we adjust the rect manually.
function window:_maximize_minimized()
	self:_maximize_frame_manually()
	self:_unminimize()
end

--zoom() doesn't work on a minimzied window, so we adjust the rect manually.
function window:_unmaximize_minimized()
	self:_unmaximize_frame_manually()
	self:_unminimize()
end

function window:maximize()
	if self:minimized() then
		if self:maximized() then
			self:_unminimize()
		else
			self:_maximize_minimized()
		end
	else
		local changed
		if not self:maximized() then
			self:_maximize_frame()
			changed = true
		end
		if not self:visible() then
			self:show()
			changed = false --show() posts changed event
		end
		if changed then
			self.frontend:_backend_changed()
		end
	end
end

function window:_unmaximize()
	self:_unmaximize_frame()
	if not self:visible() then
		self:show() --show posts changed event
	else
		self.frontend:_backend_changed()
	end
end

--save normal rect before maximizing so we can maximize from minimized.
function Window.windowShouldZoom_toFrame(cpu)
	--get arg1 from the ABI guts and set `true` as return value.
	local self
	if ffi.arch == 'x64' then
		self = ffi.cast('id', cpu.RDI.p) --RDI = self
		cpu.RAX.lo.i = true
	else
		self = ffi.cast('id', cpu.ESP.dp[1].p) --ESP[1] = self
		cpu.EAX.i = true
	end

	if not self.backend then return end --not hooked yet

	if not self._frameless then
		self.backend:_save_restore_frame()
	end
end

--state/restoring ------------------------------------------------------------

function window:restore()
	if self:minimized() then
		self:_unminimize()
	elseif self:maximized() then
		self:_unmaximize()
	elseif not self:visible() then
		self:show()
	end
end

function window:shownormal()
	if self:minimized() and self:maximized() then
		self:_unmaximize_minimized()
	else
		self:restore()
	end
end

--state/fullscreen mode ------------------------------------------------------

function window:fullscreen()
	return bit.band(tonumber(self.nswin:styleMask()),
		objc.NSFullScreenWindowMask) == objc.NSFullScreenWindowMask
end

function window:enter_fullscreen()
	if not self:visible() then
		self._entering_fs = true
		self.nswin:makeKeyAndOrderFront(nil) --NOTE: async operation
		return
	else
		self:_enter_fullscreen()
	end
end

--NOTE: toggleFullScreen() on a minimized window works.
--NOTE: close() after toggleFullScreen() results in a crash.
--NOTE: toggleFullScreen() on a closed window works.
function window:_enter_fullscreen()
	self._visible = true
	self._minimized = nil
	self.nswin:toggleFullScreen(nil) --NOTE: async operation
end

function window:exit_fullscreen()
	if not self:visible() then
		self:show()
	end
	self.nswin:toggleFullScreen(nil) --NOTE: async operation
end

function Window:windowWillEnterFullScreen()
	--fixate the maximized flag so that maximized() works while in fullscreen.
	self.backend._maximized = self.backend:maximized()
	--save the frame style and rect and change them for fullscreen.
	self.nw_stylemask = self:styleMask()
	self.nw_frame = self:frame()
	self:setStyleMask(bit.bor(
		objc.NSFullScreenWindowMask,  --fullscreen appearance
		objc.NSBorderlessWindowMask   --remove the round corners
	))
	local screen = self:screen() or objc.NSScreen:mainScreen()
	self:setFrame_display(screen:frame(), true)
	self.backend:_apply_constraints()
end

function Window:windowDidEnterFullScreen()
	self.frontend:_backend_changed()
end

function Window:windowWillExitFullScreen()
	--restore the frame style and rect to saved values.
	self:setStyleMask(self.nw_stylemask)
	self:setFrame_display(self.nw_frame, true)
	--remove the fixated _maximized flag.
	self.backend._maximized = nil
end

function Window:windowDidExitFullScreen()
	--window will exit fullscreen before closing. suppress that.
	if self.frontend:dead() then return end
	self.frontend:_backend_changed()
end

--state/enabled --------------------------------------------------------------

function window:get_enabled()
	return not self._disabled
end

function window:set_enabled(enabled)
	self._disabled = not enabled
	self:_set_movable()
end

--positioning/conversions ----------------------------------------------------

function window:_flip_y(y)
	return self.nswin:contentView():frame().size.height - y --flip y around contentView's height
end

function window:to_screen(x, y) --OSX 10.7+
	y = self:_flip_y(y)
	x, y = flip_screen_rect(nil, unpack_nsrect(self.nswin:convertRectToScreen(objc.NSMakeRect(x, y, 0, 0))))
	return x, y
end

function window:to_client(x, y) --OSX 10.7+
	y = primary_screen_h() - y
	x, y = unpack_nsrect(self.nswin:convertRectFromScreen(objc.NSMakeRect(x, y, 0, 0)))
	return x, self:_flip_y(y)
end

local function stylemask(frame)
	return (frame == 'normal' or frame == 'toolbox')
		and objc.NSTitledWindowMask or objc.NSBorderlessWindowMask
end

function app:client_to_frame(frame, has_menu, x, y, w, h)
	local style = stylemask(frame)
	local psh = primary_screen_h()
	local rect = objc.NSMakeRect(flip_screen_rect(psh, x, y, w, h))
	local rect = objc.NSWindow:frameRectForContentRect_styleMask(rect, style)
	return flip_screen_rect(psh, unpack_nsrect(rect))
end

function app:frame_to_client(frame, has_menu, x, y, w, h)
	local style = stylemask(frame)
	local psh = primary_screen_h()
	local rect = objc.NSMakeRect(flip_screen_rect(psh, x, y, w, h))
	local rect = objc.NSWindow:contentRectForFrameRect_styleMask(rect, style)
	return flip_screen_rect(psh, unpack_nsrect(rect))
end

--positioning/rectangles -----------------------------------------------------

--NOTE: framed windows are constrained to screen bounds but frameless windows are not.
function window:get_normal_rect()
	return flip_screen_rect(nil, unpack_nsrect(self.nswin:frame()))
end

function window:set_normal_rect(x, y, w, h)
	self.nswin:setFrame_display(objc.NSMakeRect(flip_screen_rect(nil, x, y, w, h)), true)
	self:_apply_constraints()
end

function window:get_frame_rect()
	return self:get_normal_rect()
end

function window:set_frame_rect(x, y, w, h)
	self:set_normal_rect(x, y, w, h)
	if self:visible() and self:minimized() then
		self:restore()
	end
end

function window:get_size()
	local sz = self.nswin:contentView():bounds().size
	return sz.width, sz.height
end

--positioning/constraints ----------------------------------------------------

local function clean(x)
	return x ~= 0 and x or nil
end
function window:get_minsize()
	local sz = self.nswin:contentMinSize()
	return clean(sz.width), clean(sz.height)
end

--clamp with optional min and max, where min takes precedence over max.
local function clamp(x, min, max)
	if max and min and max < min then max = min end
	if min then x = math.max(x, min) end
	if max then x = math.min(x, max) end
	return x
end

function window:_constrain_size(w, h)
	local minw, minh = self:get_minsize()
	local maxw, maxh = self:get_maxsize()
	w = clamp(w, minw, maxw)
	h = clamp(h, minh, maxh)
	return w, h
end

local applying
function window:_apply_constraints()
	if applying then return end
	--get window position in case we need to set it back
	local x1, y1 = self:get_normal_rect()
	--get and constrain size
	local sz = self.nswin:contentView():bounds().size
	sz.width, sz.height = self:_constrain_size(sz.width, sz.height)
	--put back constrained size
	self.nswin:setContentSize(sz)
	--reposition the window so that the top-left corner doesn't change.
	local x, y, w, h = self:get_normal_rect()
	if x ~= x1 or y ~= y1 then
		applying = true --_apply_constraints() barrier
		self:set_normal_rect(x1, y1, w, h)
		applying = nil
	end
end

function window:set_minsize(w, h)
	self.nswin:setContentMinSize(objc.NSMakeSize(w or 0, h or 0))
	self:_apply_constraints()
end

local function clean(x)
	return x ~= math.huge and x or nil
end
function window:get_maxsize()
	local sz = self.nswin:contentMaxSize()
	return clean(sz.width), clean(sz.height)
end

function window:set_maxsize(w, h)
	self.nswin:setContentMaxSize(objc.NSMakeSize(w or math.huge, h or math.huge))
	self:_apply_constraints()
end

--positioning/resizing -------------------------------------------------------

function Window:nw_clientarea_hit(event)
	local mp = event:locationInWindow()
	local rc = self:contentView():bounds()
	return box2d.hit(mp.x, mp.y, unpack_nsrect(rc))
end

local buttons = {
	objc.NSWindowCloseButton,
	objc.NSWindowMiniaturizeButton,
	objc.NSWindowZoomButton,
	objc.NSWindowToolbarButton,
	objc.NSWindowDocumentIconButton,
	objc.NSWindowDocumentVersionsButton,
	objc.NSWindowFullScreenButton,
}
function Window:nw_titlebar_buttons_hit(event)
	for i,btn in ipairs(buttons) do
		local button = self:standardWindowButton(btn)
		if button then
			if button:hitTest(button:superview():convertPoint_fromView(event:locationInWindow(), nil)) then
				return true
			end
		end
	end
end

--NOTE: there's no API to get the corner or side that a window is dragged by
--when resized, so we have to detect that manually based on mouse position.
--Getting that corner/side is needed for proper window snapping.

local function resize_area_hit(mx, my, w, h)
	local co = 15 --corner offset
	local mo = 4 --margin offset
	print(mx, my, w, h)
	if box2d.hit(mx, my, box2d.offset(co, 0, 0, 0, 0)) then
		return 'bottomleft'
	elseif box2d.hit(mx, my, box2d.offset(co, w, 0, 0, 0)) then
		return 'bottomright'
	elseif box2d.hit(mx, my, box2d.offset(co, 0, h, 0, 0)) then
		return 'topleft'
	elseif box2d.hit(mx, my, box2d.offset(co, w, h, 0, 0)) then
		return 'topright'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, 0, w, 0)) then
		return 'bottom'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, h, w, 0)) then
		return 'top'
	elseif box2d.hit(mx, my, box2d.offset(mo, 0, 0, 0, h)) then
		return 'left'
	elseif box2d.hit(mx, my, box2d.offset(mo, w, 0, 0, h)) then
		return 'right'
	end
end

function Window:nw_resize_area_hit(event)
	local mp = event:locationInWindow()
	local _, _, w, h = unpack_nsrect(self:frame())
	return resize_area_hit(mp.x, mp.y, w, h)
end

function window:_set_movable()
	self.nswin:setMovable(not self._edgesnapping and not self._disabled)
end

function window:set_edgesnapping(snapping)
	self._edgesnapping = snapping
	self:_set_movable()
end

--NOTE: No event is triggered while moving a window and frame_rect() is not
--updated either. For these reasons we take control over moving the window.
--This makes the window unmovable if/while the app blocks on the main thread.

function Window:sendEvent(event)
	if self.frontend:dead() then return end
	if self.backend._disabled then return end --disable events completely
	if self.frontend:edgesnapping() then
		--take over window dragging by the titlebar so that we can post moving events
		local etype = event:type()
		if self.dragging then
			if etype == objc.NSLeftMouseDragged then
				self:setmouse(event)
				local mx = self.frontend._mouse.x - self.dragpoint_x
				local my = self.frontend._mouse.y - self.dragpoint_y
				local x, y, w, h = flip_screen_rect(nil, unpack_nsrect(self:frame()))
				x = x + mx
				y = y + my
				local x1, y1, w1, h1 = self.frontend:_backend_resizing('move', x, y, w, h)
				if x1 or y1 or w1 or h1 then
					self:setFrame_display(objc.NSMakeRect(flip_screen_rect(nil,
						override_rect(x, y, w, h, x1, y1, w1, h1))), false)
				else
					self:setFrameOrigin(mp)
				end
				return
			elseif etype == objc.NSLeftMouseUp then
				self.dragging = false
				self.mousepos = nil
				self.frontend:_backend_end_resize'move'
				--self.backend:_end_frame_change()
				return
			end
		elseif etype == objc.NSLeftMouseDown
			and not self:nw_clientarea_hit(event)
			and not self:nw_titlebar_buttons_hit(event)
			and not self:nw_resize_area_hit(event)
		then
			self:setmouse(event)
			self:makeKeyAndOrderFront(nil) --NOTE: async operation
			self.app:activate()
			self.dragging = true
			self.dragpoint_x = self.frontend._mouse.x
			self.dragpoint_y = self.frontend._mouse.y
			self.frontend:_backend_start_resize'move'
			return
		elseif etype == objc.NSLeftMouseDown then
			self:makeKeyAndOrderFront(nil) --NOTE: async operation
			self.mousepos = event:locationInWindow() --for resizing
		end
	end
	objc.callsuper(self, 'sendEvent', event)
end

--also triggered on maximize.
function Window:windowWillStartLiveResize(notification)
	if not self.mousepos then
		self.mousepos = self:mouseLocationOutsideOfEventStream()
	end
	local mx, my = self.mousepos.x, self.mousepos.y
	local _, _, w, h = unpack_nsrect(self:frame())
	self.how = resize_area_hit(mx, my, w, h)
	self.frontend:_backend_start_resize(self.how)
end

--also triggered on maximize.
function Window:windowDidEndLiveResize()
	self.frontend:_backend_end_resize(self.how)
	--self.backend:_end_frame_change()
	self.how = nil
end

function Window:nw_resizing(w_, h_)
	if self.nw_zoomquery or not self.how then return w_, h_ end
	local x, y, w, h = flip_screen_rect(nil, unpack_nsrect(self:frame()))
	if self.how:find'top' then y, h = y + h - h_, h_ end
	if self.how:find'bottom' then h = h_ end
	if self.how:find'left' then x, w = x + w - w_, w_ end
	if self.how:find'right' then w = w_ end
	local x1, y1, w1, h1 = self.frontend:_backend_resizing(self.how, x, y, w, h)
	if x1 or y1 or w1 or h1 then
		x, y, w, h = flip_screen_rect(nil, override_rect(x, y, w, h, x1, y1, w1, h1))
	end
	return w, h
end

function Window.windowWillResize_toSize(cpu)
	if ffi.arch == 'x64' then
		--RDI = self, XMM0 = NSSize.x, XMM1 = NSSize.y
		local self = ffi.cast('id', cpu.RDI.p)
		local w = cpu.XMM[0].lo.f
		local h = cpu.XMM[1].lo.f
		w, h = self:nw_resizing(w, h)
		--return double-only structs <= 16 bytes in XMM0:XMM1
		cpu.XMM[0].lo.f = w
		cpu.XMM[1].lo.f = h
	else
		--ESP[1] = self, ESP[2] = selector, ESP[3] = sender, ESP[4] = NSSize.x, ESP[5] = NSSize.y
		local self = ffi.cast('id', cpu.ESP.dp[1].p)
		local w = cpu.ESP.dp[4].f
		local h = cpu.ESP.dp[5].f
		w, h = self:nw_resizing(w, h)
		--return values <= 8 bytes in EAX:EDX
		cpu.EAX.f = w
		cpu.EDX.f = h
	end
end

function Window:windowDidResize()
	if self.frontend:dead() then return end
	self.frontend:_backend_resized(self.how)
end

function Window:windowWillMove()
	print'willMove'
end

function Window:windowDidMove()
	self.frontend:_backend_resized()
end

--positioning/magnets --------------------------------------------------------

function window:magnets()
	local t = {} --{{x=, y=, w=, h=}, ...}

	local opt = bit.bor(
		objc.kCGWindowListOptionOnScreenOnly,
		objc.kCGWindowListExcludeDesktopElements)

	local nswin_number = tonumber(self.nswin:windowNumber())
	local list = objc.CGWindowListCopyWindowInfo(opt, nswin_number) --front-to-back order assured

	--a glimpse into the mind of a Cocoa (or Java, .Net, etc.) programmer...
	local bounds = ffi.new'CGRect[1]'
	for i = 0, tonumber(objc.CFArrayGetCount(list)-1) do
		local entry = ffi.cast('id', objc.CFArrayGetValueAtIndex(list, i)) --entry is NSDictionary
		local sharingState = entry:objectForKey(ffi.cast('id', objc.kCGWindowSharingState)):intValue()
		if sharingState ~= objc.kCGWindowSharingNone then --filter out windows we can't read from
			local layer = entry:objectForKey(ffi.cast('id', objc.kCGWindowLayer)):intValue()
			local number = entry:objectForKey(ffi.cast('id', objc.kCGWindowNumber)):intValue()
			if layer <= 0 and number ~= nswin_number then --ignore system menu, dock, etc.
				local boundsEntry = entry:objectForKey(ffi.cast('id', objc.kCGWindowBounds))
				objc.CGRectMakeWithDictionaryRepresentation(ffi.cast('CFDictionaryRef', boundsEntry), bounds)
				local x, y, w, h = unpack_nsrect(bounds[0]) --already flipped
				t[#t+1] = {x = x, y = y, w = w, h = h}
			end
		end
	end

	objc.CFRelease(ffi.cast('id', list))

	return t
end

--z-order --------------------------------------------------------------------

function window:get_topmost()
	return self.nswin:level() == objc.NSFloatingWindowLevel
end

function window:set_topmost(topmost)
	self.nswin:setLevel(topmost and objc.NSFloatingWindowLevel or objc.NSNormalWindowLevel)
end

function window:raise(relto)
	self.nswin:orderWindow_relativeTo(objc.NSWindowAbove, relto and relto.backend.nswin or 0)
end

function window:lower(relto)
	self.nswin:orderWindow_relativeTo(objc.NSWindowBelow, relto and relto.backend.nswin or 0)
end

--titlebar -------------------------------------------------------------------

function window:get_title(title)
	return objc.tolua(self.nswin:title())
end

function window:set_title(title)
	self.nswin:setTitle(title)
end

--displays -------------------------------------------------------------------

--NOTE: screen:visibleFrame() is in virtual screen coordinates just like
--winapi's MONITORINFO, which is what we want.
function app:_display(main_h, screen)
	local t = {}
	t.x, t.y, t.w, t.h = flip_screen_rect(main_h, unpack_nsrect(screen:frame()))
	t.cx, t.cy, t.cw, t.ch =
		flip_screen_rect(main_h, unpack_nsrect(screen:visibleFrame()))
	t.scalingfactor = screen:backingScaleFactor()
	return self.frontend:_display(t)
end

function app:displays()
	local screens = objc.NSScreen:screens()

	--get main_h from the screens snapshot array
	local frame = screens:objectAtIndex(0):frame() --main screen always comes first
	local main_h = frame.size.height

	--build the list of display objects to return
	local displays = {}
	for i = 0, tonumber(screens:count()-1) do
		table.insert(displays, self:_display(main_h, screens:objectAtIndex(i)))
	end
	return displays
end

function app:display_count()
	return tonumber(objc.NSScreen:screens():count())
end

function app:main_display()
	return self:_display(nil, objc.NSScreen:screens():objectAtIndex(0)) --main screen always comes first
end

--NOTE: mainScreen() actually means the screen which has keyboard focus.
function app:active_display()
	return self:_display(nil, objc.NSScreen:mainScreen() or screens:objectAtIndex(0))
end

--NOTE: screen() works on an initially hidden window.
--NOTE: screen() works on a closed window.
--NOTE: screen() returns nil on an orderOut() window.
--NOTE: screen() returns nil on an off-screen window (frameless windows can be made off-screen).
function window:display()
	local screen = self.nswin:screen()
	return screen and self.app:_display(nil, screen)
end

function App:applicationDidChangeScreenParameters()
	self.frontend:_backend_displays_changed()
end

--cursors --------------------------------------------------------------------

--NOTE: can't reference resizing cursors directly with constants, hence load_hicursor().

local cursors = {
	--pointers
	arrow = 'arrowCursor',
	text  = 'IBeamCursor',
	hand  = 'openHandCursor',
	cross = 'crosshairCursor',
	--app state
	busy_arrow = 'busyButClickableCursor', --undocumented, whatever
}

local hi_cursors = {
	--pointers
	forbidden  = 'notallowed',
	--move and resize
	size_diag1 = 'resizenortheastsouthwest',
	size_diag2 = 'resizenorthwestsoutheast',
	size_h     = 'resizeeastwest',
	size_v     = 'resizenorthsouth',
	move       = 'move',
}

local load_hicursor = objc.memoize(function(name)
	basepath = basepath or objc.findframework(
		'ApplicationServices.HIServices/Versions/Current/Resources/cursors')
	local curpath = string.format('%s/%s/cursor.pdf', basepath, name)
	local infopath = string.format('%s/%s/info.plist', basepath, name)
	local image = objc.NSImage:alloc():initByReferencingFile(curpath)
	local info = objc.NSDictionary:dictionaryWithContentsOfFile(infopath)
	local hotx = info:objectForKey('hotx'):doubleValue()
	local hoty = info:objectForKey('hoty'):doubleValue()
	return objc.NSCursor:alloc():initWithImage_hotSpot(image, objc.NSMakePoint(hotx, hoty))
end)

local function load_cursor(name)
	if cursors[name] then
		return objc.NSCursor[cursors[name]](objc.NSCursor)
	elseif hi_cursors[name] then
		return load_hicursor(hi_cursors[name])
	else
		error'invalid cursor'
	end
end

function window:update_cursor()
	self.nswin:invalidateCursorRectsForView(self.nswin:contentView()) --trigger cursorUpdate
end

function Window:cursorUpdate(event)
	if self:nw_clientarea_hit(event) then
		local cursor, visible = self.frontend:cursor()
		if visible then
			load_cursor(cursor):set()
			objc.NSCursor:unhide()
		else
			objc.NSCursor:hide()
		end
	else
		objc.callsuper(self, 'cursorUpdate', event)
	end
end

--keyboard -------------------------------------------------------------------


--NOTE: there's no keyDown() for modifier keys, must use flagsChanged().
--NOTE: flagsChanged() returns undocumented, and possibly not portable bits to distinguish
--between left/right modifier keys. these bits are not given with NSEvent:modifierFlags(),
--so we can't get the initial state of specific modifier keys.
--NOTE: there's no keyDown() on the 'help' key (which is the 'insert' key on a win keyboard).
--NOTE: flagsChanged() can only get you so far in simulating keyDown/keyUp events for the modifier keys:
--  holding down these keys won't trigger repeated key events.
--  can't know when capslock is depressed, only when it is pressed.

local keynames = {

	[objc.kVK_ANSI_0] = '0',
	[objc.kVK_ANSI_1] = '1',
	[objc.kVK_ANSI_2] = '2',
	[objc.kVK_ANSI_3] = '3',
	[objc.kVK_ANSI_4] = '4',
	[objc.kVK_ANSI_5] = '5',
	[objc.kVK_ANSI_6] = '6',
	[objc.kVK_ANSI_7] = '7',
	[objc.kVK_ANSI_8] = '8',
	[objc.kVK_ANSI_9] = '9',

	[objc.kVK_ANSI_A] = 'A',
	[objc.kVK_ANSI_B] = 'B',
	[objc.kVK_ANSI_C] = 'C',
	[objc.kVK_ANSI_D] = 'D',
	[objc.kVK_ANSI_E] = 'E',
	[objc.kVK_ANSI_F] = 'F',
	[objc.kVK_ANSI_G] = 'G',
	[objc.kVK_ANSI_H] = 'H',
	[objc.kVK_ANSI_I] = 'I',
	[objc.kVK_ANSI_J] = 'J',
	[objc.kVK_ANSI_K] = 'K',
	[objc.kVK_ANSI_L] = 'L',
	[objc.kVK_ANSI_M] = 'M',
	[objc.kVK_ANSI_N] = 'N',
	[objc.kVK_ANSI_O] = 'O',
	[objc.kVK_ANSI_P] = 'P',
	[objc.kVK_ANSI_Q] = 'Q',
	[objc.kVK_ANSI_R] = 'R',
	[objc.kVK_ANSI_S] = 'S',
	[objc.kVK_ANSI_T] = 'T',
	[objc.kVK_ANSI_U] = 'U',
	[objc.kVK_ANSI_V] = 'V',
	[objc.kVK_ANSI_W] = 'W',
	[objc.kVK_ANSI_X] = 'X',
	[objc.kVK_ANSI_Y] = 'Y',
	[objc.kVK_ANSI_Z] = 'Z',

	[objc.kVK_ANSI_Semicolon]    = ';',
	[objc.kVK_ANSI_Equal]        = '=',
	[objc.kVK_ANSI_Comma]        = ',',
	[objc.kVK_ANSI_Minus]        = '-',
	[objc.kVK_ANSI_Period]       = '.',
	[objc.kVK_ANSI_Slash]        = '/',
	[objc.kVK_ANSI_Grave]        = '`',
	[objc.kVK_ANSI_LeftBracket]  = '[',
	[objc.kVK_ANSI_Backslash]    = '\\',
	[objc.kVK_ANSI_RightBracket] = ']',
	[objc.kVK_ANSI_Quote]        = '\'',

	[objc.kVK_Delete] = 'backspace',
	[objc.kVK_Tab]    = 'tab',
	[objc.kVK_Space]  = 'space',
	[objc.kVK_Escape] = 'esc',
	[objc.kVK_Return] = 'enter!',

	[objc.kVK_F1]  = 'F1',
	[objc.kVK_F2]  = 'F2',
	[objc.kVK_F3]  = 'F3',
	[objc.kVK_F4]  = 'F4',
	[objc.kVK_F5]  = 'F5',
	[objc.kVK_F6]  = 'F6',
	[objc.kVK_F7]  = 'F7',
	[objc.kVK_F8]  = 'F8',
	[objc.kVK_F9]  = 'F9',
	[objc.kVK_F10] = 'F10',
	[objc.kVK_F11] = 'F11', --taken on mac (show desktop)
	[objc.kVK_F12] = 'F12', --taken on mac (show dashboard)

	[objc.kVK_CapsLock] = 'capslock',

	[objc.kVK_LeftArrow]     = 'left!',
	[objc.kVK_UpArrow]       = 'up!',
	[objc.kVK_RightArrow]    = 'right!',
	[objc.kVK_DownArrow]     = 'down!',

	[objc.kVK_PageUp]        = 'pageup!',
	[objc.kVK_PageDown]      = 'pagedown!',
	[objc.kVK_Home]          = 'home!',
	[objc.kVK_End]           = 'end!',
	[objc.kVK_Help]          = 'help', --mac keyboard; 'insert!' key on win keyboard; no keydown, only keyup
	[objc.kVK_ForwardDelete] = 'delete!',

	[objc.kVK_ANSI_Keypad0] = 'num0',
	[objc.kVK_ANSI_Keypad1] = 'num1',
	[objc.kVK_ANSI_Keypad2] = 'num2',
	[objc.kVK_ANSI_Keypad3] = 'num3',
	[objc.kVK_ANSI_Keypad4] = 'num4',
	[objc.kVK_ANSI_Keypad5] = 'num5',
	[objc.kVK_ANSI_Keypad6] = 'num6',
	[objc.kVK_ANSI_Keypad7] = 'num7',
	[objc.kVK_ANSI_Keypad8] = 'num8',
	[objc.kVK_ANSI_Keypad9] = 'num9',
	[objc.kVK_ANSI_KeypadDecimal]  = 'num.',
	[objc.kVK_ANSI_KeypadMultiply] = 'num*',
	[objc.kVK_ANSI_KeypadPlus]     = 'num+',
	[objc.kVK_ANSI_KeypadMinus]    = 'num-',
	[objc.kVK_ANSI_KeypadDivide]   = 'num/',
	[objc.kVK_ANSI_KeypadEquals]   = 'num=',     --mac keyboard
	[objc.kVK_ANSI_KeypadEnter]    = 'numenter',
	[objc.kVK_ANSI_KeypadClear]    = 'numclear', --mac keyboard; 'numlock' key on win keyboard

	[objc.kVK_Mute]       = 'mute',
	[objc.kVK_VolumeDown] = 'volumedown',
	[objc.kVK_VolumeUp]   = 'volumeup',

	[110] = 'menu', --win keyboard

	[objc.kVK_F13] = 'F13', --mac keyboard; win keyboard 'printscreen' key
	[objc.kVK_F14] = 'F14', --mac keyboard; win keyboard 'scrolllock' key; taken (brightness down)
	[objc.kVK_F15] = 'F15', --mac keyboard; win keyboard 'break' key; taken (brightness up)
	[objc.kVK_F16] = 'F16', --mac keyboard
	[objc.kVK_F17] = 'F17', --mac keyboard
	[objc.kVK_F18] = 'F18', --mac keyboard
	[objc.kVK_F15] = 'F19', --mac keyboard
}

local keycodes = {}
for vk, name in pairs(keynames) do
	keycodes[name:lower()] = vk
end

local function modifier_flag(mask, flags)
	flags = flags or tonumber(objc.NSEvent:modifierFlags())
	return bit.band(flags, mask) ~= 0
end

local function capslock_state(flags)
	return modifier_flag(objc.NSAlphaShiftKeyMask, flags)
end

local keystate
local capsstate

function Window:reset_keystate()
	--note: platform-dependent flagbits are not given with NSEvent:modifierFlags() nor with GetKeys(),
	--so we can't get the initial state of specific modifier keys.
	keystate = {}
	capsstate = capslock_state()
end

local function keyname(event)
	local keycode = event:keyCode()
	return keynames[keycode]
end

function Window:keyDown(event)
	local key = keyname(event)
	if not key then return end
	if not event:isARepeat() then
		self.frontend:_backend_keydown(key)
	end
	self.frontend:_backend_keypress(key)

	--interpret key to generate insertText()
	self:interpretKeyEvents(objc.NSArray:arrayWithObject(event))
end

function Window:insertText(s)
	local s = objc.tolua(s)
	if s == '' then return end --dead key
	--if s:byte(1) > 31 and s:byte(1) < 127 then --not a control key
	self.frontend:_backend_keychar(s)
end

function Window:keyUp(event)
	local key = keyname(event)
	if not key then return end
	if key == 'help' then --simulate the missing keydown for the help/insert key
		self.frontend:_backend_keydown(key)
	end
	self.frontend:_backend_keyup(key)
end

local flagbits = {
	--undocumented bits tested on a macbook with US keyboard
	lctrl    = 2^0,
	lshift   = 2^1,
	rshift   = 2^2,
	lcommand = 2^3, --'lwin' key on PC keyboard
	rcommand = 2^4, --'rwin' key on PC keyboard; 'altgr' key on german PC keyboard
	lalt     = 2^5,
	ralt     = 2^6,
	--bits for PC keyboard
	rctrl    = 2^13,
}

function Window:flagsChanged(event)
	--simulate key pressing for capslock
	local newcaps = capslock_state()
	local oldcaps = capsstate
	if newcaps ~= oldcaps then
		capsstate = newcaps
		keystate.capslock = true
		self.frontend:_backend_keydown'capslock'
		keystate.capslock = false
		self.frontend:_backend_keyup'capslock'
	end

	--detect keydown/keyup state change for modifier keys
	local flags = tonumber(event:modifierFlags())
	for name, mask in pairs(flagbits) do
		local oldstate = keystate[name] or false
		local newstate = bit.band(flags, mask) ~= 0
		if oldstate ~= newstate then
			keystate[name] = newstate
			if newstate then
				self.frontend:_backend_keydown(name)
				self.frontend:_backend_keypress(name)
			else
				self.frontend:_backend_keyup(name)
			end
		end
	end
end

local alt_names = { --ambiguous keys that have a single physical key mapping on mac
	left     = 'left!',
	up       = 'up!',
	right    = 'right!',
	down     = 'down!',
	pageup   = 'pageup!',
	pagedown = 'pagedown!',
	['end']  = 'end!',
	home     = 'home!',
	insert   = 'insert!',
	delete   = 'delete!',
	enter    = 'enter!',
}

local keymap, pkeymap

function app:key(name)
	if name == '^capslock' then
		return capsstate
	elseif name == '^numlock' then
		return false --TODO
	elseif name == '^scrolllock' then
		return false --TODO
	elseif name == 'capslock' then
		return keystate.capslock
	elseif name == 'shift' then
		return keystate.lshift or keystate.rshift or false
	elseif name == 'ctrl' then
		return keystate.lctrl or keystate.rctrl or false
	elseif name == 'alt' then
		return keystate.lalt or keystate.ralt or false
	elseif name == 'command' then
		return keystate.lcommand or keystate.rcommand or false
	elseif flagbits[name] then --get modifier saved state
		return keystate[name] or false
	else --get normal key state
		local keycode = keycodes[name] or keycodes[alt_names[name]]
		if not keycode then return false end
		keymap  = keymap or ffi.new'unsigned char[16]'
		pkeymap = pkeymap or ffi.cast('void*', keymap)
		objc.GetKeys(pkeymap)
		return bit.band(bit.rshift(keymap[bit.rshift(keycode, 3)], bit.band(keycode, 7)), 1) ~= 0
	end
end

--mouse ----------------------------------------------------------------------

function app:double_click_time()
	return objc.NSEvent:doubleClickInterval() --seconds
end

function app:double_click_target_area()
	return 4, 4 --like in Windows
end

function Window:setmouse(event)
	local m = self.frontend._mouse
	local pos = event:locationInWindow()
	m.x = pos.x
	m.y = self.backend:_flip_y(pos.y)
	local btns = tonumber(event:pressedMouseButtons())
	m.left = bit.band(btns, 1) ~= 0
	m.right = bit.band(btns, 2) ~= 0
	m.middle = bit.band(btns, 4) ~= 0
	m.ex1 = bit.band(btns, 8) ~= 0
	m.ex2 = bit.band(btns, 16) ~= 0
	return m
end

--disable mousemove events when exiting client area, but only if no mouse
--buttons are down, to emulate Windows behavior.
function window:_check_mousemove(event, m)
	if not m.inside and event:pressedMouseButtons() == 0 then
		self.nswin:setAcceptsMouseMovedEvents(false)
	end
end

function Window:mouseDown(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown('left', m.x, m.y)
end

function Window:mouseUp(event)
	local m = self:setmouse(event)
	self.backend:_check_mousemove(event, m)
	self.frontend:_backend_mouseup('left', m.x, m.y)
end

function Window:rightMouseDown(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown('right', m.x, m.y)
end

function Window:rightMouseUp(event)
	local m = self:setmouse(event)
	self.backend:_check_mousemove(event, m)
	self.frontend:_backend_mouseup('right', m.x, m.y)
end

local other_buttons = {'', 'middle', 'ex1', 'ex2'}

function Window:otherMouseDown(event)
	local btn = other_buttons[tonumber(event:buttonNumber())]
	if not btn then return end
	local m = self:setmouse(event)
	self.frontend:_backend_mousedown(btn, m.x, m.y)
end

function Window:otherMouseUp(event)
	local btn = other_buttons[tonumber(event:buttonNumber())]
	if not btn then return end
	local m = self:setmouse(event)
	self.backend:_check_mousemove(event, m)
	self.frontend:_backend_mouseup(btn, m.x, m.y)
end

function Window:mouseMoved(event)
	local m = self:setmouse(event)
	self.frontend:_backend_mousemove(m.x, m.y)
end

function Window:mouseDragged(event)
	self:mouseMoved(event)
end

function Window:rightMouseDragged(event)
	self:mouseMoved(event)
end

function Window:otherMouseDragged(event)
	self:mouseMoved(event)
end

function Window:mouseEntered(event)
	local m = self:setmouse(event)
	m.inside = true
	--enable mousemove events only inside the client area to emulate Windows behavior.
	self:setAcceptsMouseMovedEvents(true)
	--mute mousenter() if buttons are pressed to emulate Windows behavior.
	if event:pressedMouseButtons() ~= 0 then return end
	self.frontend:_backend_mouseenter()
end

function Window:mouseExited(event)
	local m = self:setmouse(event)
	m.inside = false
	self.backend:_check_mousemove(event, m)
	--mute mouseleave() if buttons are pressed to emulate Windows behavior.
	if event:pressedMouseButtons() ~= 0 then return end
	self.frontend:_backend_mouseleave()
end

function Window:scrollWheel(event)
	local m = self:setmouse(event)
	local x, y = m.x, m.y
	local dx = event:deltaX()
	if dx ~= 0 then
		self.frontend:_backend_mousehwheel(dx, x, y)
	end
	local dy = event:deltaY()
	if dy ~= 0 then
		self.frontend:_backend_mousewheel(dy, x, y)
	end
end

function window:mouse_pos()
	--return objc.NSEvent:
end

function Window:acceptsFirstMouse()
	--get mouseDown when clicked while not active to emulate Windows behavior.
	return true
end

--dynamic bitmaps ------------------------------------------------------------

ffi.cdef[[
void* malloc (size_t size);
void  free   (void*);
]]

local function malloc(size)
	local data = ffi.C.malloc(size)
	assert(data ~= nil, 'out of memory')
	return data
end

--make a bitmap that can be painted on the current NSGraphicsContext.
--to that effect, a paint() function and a free() function are provided along with the bitmap.
local function make_bitmap(w, h)

	--can't create a zero-sized bitmap
	if w <= 0 or h <= 0 then return end

	local stride = w * 4
	local size = stride * h

	local data = malloc(size)

	local bitmap = {
		w = w,
		h = h,
		data = data,
		stride = stride,
		size = size,
		format = 'bgra8',
	}

	local colorspace = objc.CGColorSpaceCreateDeviceRGB()
	local provider = objc.CGDataProviderCreateWithData(nil, data, size, nil)

	--little-endian alpha-first, i.e. bgra8
	local info = bit.bor(objc.kCGBitmapByteOrder32Little, objc.kCGImageAlphaPremultipliedFirst)

	local bounds = ffi.new'CGRect'
	bounds.size.width = w / 2
	bounds.size.height = h / 2

	local function paint()

		--CGImage expects the pixel buffer to be immutable, which is why
		--we create a new one every time. bummer.
		local image = objc.CGImageCreate(w, h,
			8,  --bpc
			32, --bpp
			stride,
			colorspace,
			info,
			provider,
			nil, --no decode
			false, --no interpolation
			objc.kCGRenderingIntentDefault)

		--get the current graphics context and draw our image on it.
		local context = objc.NSGraphicsContext:currentContext()
		local graphicsport = context:graphicsPort()
		context:setCompositingOperation(objc.NSCompositeCopy)
		objc.CGContextDrawImage(graphicsport, bounds, image)

		objc.CGImageRelease(image)
	end

	local function free()

		--trigger a user-supplied destructor
		if bitmap.free then
			bitmap:free()
		end

		--free image args
		objc.CGColorSpaceRelease(colorspace)
		objc.CGDataProviderRelease(provider)

		--free the bitmap
		ffi.C.free(data)
		bitmap.data = nil
		bitmap = nil
	end

	return bitmap, free, paint
end

--a dynamic bitmap is an API that creates a new bitmap everytime its size
--changes. user supplies the :size() function, :get() gets the bitmap,
--and :freeing(bitmap) is triggered before the bitmap is freed.
local function dynbitmap(api)

	api = api or {}

	local w, h, bitmap, free, paint

	function api:get()
		local w1, h1 = api:size()
		w1 = w1 * 2
		h1 = h1 * 2
		if w1 ~= w or h1 ~= h then
			self:free()
			bitmap, free, paint = make_bitmap(w1, h1)
			w, h = w1, h1
		end
		return bitmap
	end

	function api:free()
		if not free then return end
		self:freeing(bitmap)
		free()
	end

	function api:paint()
		if not paint then return end
		paint()
	end

	return api
end

--repaint views --------------------------------------------------------------

--a repaint view calls the Lua method nw_repaint() on drawRect().

local RepaintView = objc.class('View', 'NSView')

function RepaintView.drawRect(cpu)

	--get arg1 from the ABI guts.
	local self
	if ffi.arch == 'x64' then
		self = ffi.cast('id', cpu.RDI.p) --RDI = self
	else
		self = ffi.cast('id', cpu.ESP.dp[1].p) --ESP[1] = self
	end

	self:nw_repaint()
end

--rendering ------------------------------------------------------------------

function window:_init_content_view()

	--create the dynbitmap to paint on the content view.
	self._dynbitmap = dynbitmap{
		size = function()
			return self.frontend:size()
		end,
		freeing = function(_, bitmap)
			self.frontend:_backend_free_bitmap(bitmap)
		end,
	}

	--create our custom view and set it as the content view.
	local bounds = self.nswin:contentView():bounds()
	self.nsview = RepaintView:alloc():initWithFrame(bounds)

	function self.nsview.nw_repaint()
		--let the user request the bitmap and draw on it.
		self.frontend:_backend_repaint()
		--paint the bitmap on the current graphics context.
		self._dynbitmap:paint()
	end

	self.nswin:setContentView(self.nsview)
end

function window:bitmap()
	return self._dynbitmap:get()
end

function window:_free_bitmap()
	self._dynbitmap:free()
end

function window:invalidate(x, y, w, h)
	if x then
		self.nswin:contentView():setNeedsDisplayInRect(objc.NSMakeRect(x, y, w, h))
	else
		self.nswin:contentView():setNeedsDisplay(true)
	end
end

--views ----------------------------------------------------------------------

--NOTE: you can't put a view in front of an OpenGL view. You can put a child NSWindow,
--which will follow the parent around, but it won't be clipped by the parent.

local view = {}
window.view = view

function view:new(window, frontend, t)
	local self = glue.inherit({
		window = window,
		app = window.app,
		frontend = frontend,
	}, self)

	self:_init(t)

	return self
end

glue.autoload(window, {
	cairoview = 'nw_cocoa_cairoview',
	glview    = 'nw_cocoa_glview',
})

function window:getcairoview()
	return self.cairoview
end

--hi-dpi support -------------------------------------------------------------

function app:get_autoscaling()
	return false --always off
end

function app:enable_autoscaling()
	--NOTE: not supported.
end

function app:disable_autoscaling()
	--NOTE: nothing to disable, it's always off
end

function Window:windowDidChangeBackingProperties()
	local scalingfactor = self:screen():backingScaleFactor()
	self.frontend:_backend_scalingfactor_changed(scalingfactor)
end

--menus ----------------------------------------------------------------------

local menu = {}
nw._menu_class = menu

function app:_init_menubar()
	--NOTE: the app's menu bar _and_ the app menu (the first menu item) must be created
	--before the app is activated, otherwise the app menu title will be replaced with
	--a little apple icon to your desperation!
	local menubar = objc.NSMenu:new()
	menubar:setAutoenablesItems(false)
	self.nsapp:setMainMenu(menubar)
	ffi.gc(menubar, nil)
	local appmenu = objc.NSMenu:new()
	local appmenuitem = objc.NSMenuItem:new()
	appmenuitem:setSubmenu(appmenu)
	ffi.gc(appmenu, nil)
	menubar:addItem(appmenuitem)
	ffi.gc(appmenuitem, nil)
end

function app:menu()
	local nsmenu = objc.NSMenu:new()
	nsmenu:setAutoenablesItems(false)
	return menu:_new(self, nsmenu)
end

function menu:_new(app, nsmenu)
	local self = glue.inherit({app = app, nsmenu = nsmenu}, menu)
	nsmenu.nw_backend = self
	return self
end

objc.addmethod('App', 'nw_menuItemClicked', function(self, item)
	item.nw_action()
end, 'v@:@')

function menu:_setitem(item, args)
	if not item then
		if args.separator then
			item = objc.NSMenuItem:separatorItem()
		else
			item = objc.NSMenuItem:new()
		end
	end
	item:setTitle(args.text)
	item:setState(args.checked and objc.NSOnState or objc.NSOffState)
	item:setEnabled(args.enabled)
	item:setKeyEquivalent('G')
	item:setKeyEquivalentModifierMask(bit.bor(
		objc.NSShiftKeyMask,
		objc.NSAlternateKeyMask,
		objc.NSCommandKeyMask,
		objc.NSControlKeyMask))
	if args.submenu then
		local nsmenu = args.submenu.backend.nsmenu
		nsmenu:setTitle(args.text) --the menu item uses nenu's title!
		item:setSubmenu(nsmenu)
	elseif args.action then
		item:setTarget(self.app.nsapp)
		item:setAction'nw_menuItemClicked'
		item.nw_action = args.action
	end
	return item
end

local function dump_menuitem(item)
	return {
		text = objc.tolua(item:title()),
		action = item:submenu() and item:submenu().nw_backend.frontend or item.nw_action,
		checked = item:state() == objc.NSOnState,
		enabled = item:isEnabled(),
	}
end

function menu:add(index, args)
	local item = self:_setitem(nil, args)
	if index then
		self.nsmenu:insertItem_atIndex(item, index-1)
	else
		self.nsmenu:addItem(item)
		index = self.nsmenu:numberOfItems()
	end
	ffi.gc(item, nil) --disown, nsmenu owns it now
	return index
end

function menu:set(index, args)
	local item = self.nsmenu:itemAtIndex(index-1)
	self:_setitem(item, args)
end

function menu:get(index)
	return dump_menuitem(self.nsmenu:itemAtIndex(index-1))
end

function menu:item_count()
	return tonumber(self.nsmenu:numberOfItems())
end

function menu:remove(index)
	self.nsmenu:removeItemAtIndex(index-1)
end

function menu:get_checked(index)
	return self.nsmenu:itemAtIndex(index-1):state() == objc.NSOnState
end

function menu:set_checked(index, checked)
	self.nsmenu:itemAtIndex(index-1):setState(checked and objc.NSOnState or objc.NSOffState)
end

function menu:get_enabled(index)
	return self.nsmenu:itemAtIndex(index-1):isEnabled()
end

function menu:set_enabled(index, enabled)
	self.nsmenu:itemAtIndex(index-1):setEnabled(enabled)
end

--in OSX, there's a single menu bar for the whole app.
function app:menubar()
	if not self._menu then
		local nsmenu = self.nsapp:mainMenu()
		self._menu = menu:_new(self, nsmenu)
		self._menu:remove(1) --remove the dummy app menu created on app startup
	end
	return self._menu
end

function window:popup(menu, x, y)
	local p = objc.NSMakePoint(x, self:_flip_y(y))
	menu.backend.nsmenu:popUpMenuPositioningItem_atLocation_inView(nil, p, self.nswin:contentView())
end

--notification icons ---------------------------------------------------------

local notifyicon = {}
app.notifyicon = notifyicon

function notifyicon:new(app, frontend, opt)
	self = glue.inherit({app = app, frontend = frontend}, notifyicon)

	local length = opt and opt.length or self:_bitmap_size()
	self.si = objc.NSStatusBar:systemStatusBar():statusItemWithLength(length)
	self.si.backend = self
	self.si.frontend = frontend

	self._dynbitmap = dynbitmap{
		size = function()
			return self:_bitmap_size()
		end,
		freeing = function(_, bitmap)
			self.frontend:_backend_free_bitmap(bitmap)
			self.si:setImage(nil)
			self.nsimage:release()
			self.nsimage = nil
		end,
	}

	self.si:setHighlightMode(true)

	if opt and opt.tooltip then self:set_tooltip(opt.tooltip) end
	if opt and opt.menu then self:set_menu(opt.menu) end
	if opt and opt.text then self:set_text(opt.text) end

	return self
end

function notifyicon:free()
	self._dynbitmap:free()
	objc.NSStatusBar:systemStatusBar():removeStatusItem(self.si)
	self.si:release()
	self.si = nil
end

function notifyicon:bitmap()
	return self._dynbitmap:get()
end

function notifyicon:_bitmap_size()
	local h = objc.NSStatusBar:systemStatusBar():thickness()
	return h, h --return a square rectangle to emulate Windows behavior
end

function notifyicon:invalidate()
	self.frontend:_backend_repaint()
	if not self.nsimage then
		self.nsimage = objc.NSImage:alloc():initWithSize(objc.NSMakeSize(self:_bitmap_size()))
	end
	self.nsimage:lockFocus()
	self._dynbitmap:paint()
	self.nsimage:unlockFocus()
	--we have to set the image every time or the icon won't be updated.
	self.si:setImage(self.nsimage)
end

function notifyicon:rect()
	return flip_screen_rect(nil, unpack_nsrect(self.si:valueForKey('window'):frame()))
end

function notifyicon:get_tooltip()
	return objc.tolua(self.si:tooltip())
end

function notifyicon:set_tooltip(tooltip)
	self.si:setToolTip(tooltip)
end

function notifyicon:get_menu()
	return self.menu
end

function notifyicon:set_menu(menu)
	self.menu = menu
	self.si:setMenu(menu.backend.nsmenu)
end

function notifyicon:get_text() --OSX specific
	return objc.tolua(self.si:title())
end

function notifyicon:set_text(text) --OSX specific
	self.si:setTitle(text)
end

function notifyicon:get_length() --OSX specific
	return self.si:length()
end

function notifyicon:set_length(length) --OSX specific
	self.si:setLength(length)
end

--window icon ----------------------------------------------------------------

--TODO: self.nswin:standardWindowButton(objc.NSWindowDocumentIconButton) returns null
--TODO: the window icon for OSX has a different purpose and there's only one, not two.

function window:_icon_size()
	self.nswin:standardWindowButton(objc.NSWindowDocumentIconButton):image():size()
end

function window:icon_bitmap()
	if not self._icon_dynbitmap then
		--create the dynbitmap to paint on the content view.
		self._icon_dynbitmap = dynbitmap{
			size = function()
				return self:_icon_size()
			end,
			freeing = function(_, bitmap)
				self.frontend:_backend_icon_free_bitmap(bitmap)
				self.nswin:standardWindowButton(objc.NSWindowDocumentIconButton):setImage(nil)
				self.nsiconimage:release()
				self.nsiconimage = nil
			end,
		}
	end
	return self._icon_dynbitmap:get()
end

function window:invalidate_icon()
	if not self._icon_dynbitmap then return end
	if not self.nsiconimage then
		self.nsiconimage = objc.NSImage:alloc():initWithSize(objc.NSMakeSize(self:_icon_size()))
	end
	self.nsiconimage:lockFocus()
	self._icon_dynbitmap:paint()
	self.nsiconimage:unlockFocus()
	--we must set the image every time or the icon won't be updated.
	self.nswin:standardWindowButton(objc.NSWindowDocumentIconButton):setImage(self.nsiconimage)
end

--dock icon ------------------------------------------------------------------

function app:_dockicon_size()
	local sz = self.nsapp:dockTile():size()
	return sz.width, sz.height
end

function app:dockicon_bitmap()
	if not self._dockicon_dynbitmap then
		--create the dynbitmap to paint on the content view.
		self._dockicon_dynbitmap = dynbitmap{
			size = function()
				return self:_dockicon_size()
			end,
			freeing = function(_, bitmap)
				self.frontend:_backend_dockicon_free_bitmap(bitmap)
			end,
		}
	end
	return self._dockicon_dynbitmap:get()
end

function app:dockicon_invalidate()
	if not self.dkview then
		--create our custom view and set it as the content view.
		self.dkview = RepaintView:alloc():init()

		function self.dkview.nw_repaint()

			--let the user request the bitmap and draw on it.
			self.frontend:_backend_dockicon_repaint()

			--paint the bitmap on the current graphics context.
			if self._dockicon_dynbitmap then
				self._dockicon_dynbitmap:paint()
			end
		end

		self.nsapp:dockTile():setContentView(self.dkview)
	end
	self.nsapp:dockTile():display()
end

function app:dockicon_free()
	if self._dockicon_dynbitmap then
		self._dockicon_dynbitmap:free()
		self._dockicon_dynbitmap = nil
	end
	if self.dkview then
		self.nsapp:dockTile():setContentView(nil)
		self.dkview:release()
		self.dkview = nil
	end
end

--file chooser ---------------------------------------------------------------

function app:opendialog(opt)
	local dlg = objc.NSOpenPanel:openPanel()

	if opt.title then
		dlg:setTitle(opt.title)
	end
	dlg:setCanChooseFiles(true)
	dlg:setCanChooseDirectories(false) --because Windows can't
	if opt.filetypes then
		dlg:setAllowedFileTypes(opt.filetypes)
		dlg:setAllowsOtherFileTypes(not opt.filetypes)
	end
	if opt.multiselect then
		dlg:setAllowsMultipleSelection(true)
	end

	if dlg:runModal() == objc.NSOKButton then
		local files = dlg:URLs()
		local t = {}
		for i = 0, files:count()-1 do
			t[#t+1] = objc.tolua(files:objectAtIndex(i):path())
		end
		dlg:release()
		return t
	end
	dlg:release()
end

function app:savedialog(opt)
	local dlg = objc.NSSavePanel:savePanel()

	if opt.title then
		dlg:setTitle(opt.title)
	end
	if opt.filetypes then
		dlg:setAllowedFileTypes(opt.filetypes)
		dlg:setAllowsOtherFileTypes(not opt.filetypes)
	end
	if opt.path then
		dlg:setDirectoryURL(objc.NSURL:fileURLWithPath(opt.path))
	end
	if opt.filename then
		dlg:setNameFieldStringValue(opt.filename)
	end

	if dlg:runModal() == objc.NSOKButton then
		dlg:release()
		return objc.tolua(dlg:URL():path())
	end
	dlg:release()
end

--clipboard ------------------------------------------------------------------

--make a NSImage from a bgra8 bitmap.
local function bitmap_to_nsimage(bitmap)

	assert(bitmap.format == 'bgra8', 'invalid bitmap format')

	local colorspace = objc.CGColorSpaceCreateDeviceRGB()
	local provider = objc.CGDataProviderCreateWithData(nil, bitmap.data, bitmap.size, nil)

	--little-endian alpha-first, i.e. bgra8
	local info = bit.bor(objc.kCGBitmapByteOrder32Little, objc.kCGImageAlphaPremultipliedFirst)

	local cgimage = objc.CGImageCreate(bitmap.w, bitmap.h,
		8,  --bpc
		32, --bpp
		bitmap.stride,
		colorspace,
		info,
		provider,
		nil, --no decode
		false, --no interpolation
		objc.kCGRenderingIntentDefault)

	local nsimage = objc.NSImage:alloc():initWithCGImage_size(cgimage, objc.NSZeroSize)

	objc.CGImageRelease(cgimage)
	objc.CGColorSpaceRelease(colorspace)
	objc.CGDataProviderRelease(provider)

	return nsimage
end

--make a rgba8 bitmap from a NSImage.
local function nsimage_to_bitmap(nsimage)

	local sz = nsimage:size()
	local w, h = sz.width, sz.height
	local stride = w * 4
	local size = stride * h

	local data = malloc(size)

	local bitmap = {
		w = w,
		h = h,
		stride = stride,
		size = size,
		data = data,
		format = 'bgra8',
	}

	local info = bit.bor(objc.kCGBitmapByteOrder32Little, objc.kCGImageAlphaPremultipliedFirst)
	local colorspace = objc.CGColorSpaceCreateDeviceRGB()
	local cgcontext = objc.CGBitmapContextCreate(data, w, h, 8, stride, colorspace, info)
	local nscontext = objc.NSGraphicsContext:graphicsContextWithGraphicsPort_flipped(cgcontext, false)
	objc.NSGraphicsContext:setCurrentContext(nscontext)
	nsimage:drawInRect(objc.NSMakeRect(0, 0, w, h))
	objc.NSGraphicsContext:setCurrentContext(nil)
	nscontext:release()
	objc.CGContextRelease(cgcontext)
	objc.CGColorSpaceRelease(colorspace)

	return bitmap
end

local type_map = {
	text = objc.tolua(objc.NSStringPboardType),
	files = objc.tolua(objc.NSFilenamesPboardType),
	bitmap = objc.tolua(objc.NSTIFFPboardType),
}

local rev_type_map = glue.index(type_map)

function app:clipboard_formats()
	local pasteboard = objc.NSPasteboard:generalPasteboard()
	local t = {}
	for i,elem in objc.ipairs(pasteboard:types()) do
		--print(i, objc.tolua(elem))
		t[#t+1] = rev_type_map[objc.tolua(elem)]
	end
	return t
end

function app:get_clipboard(format)
	local pasteboard = objc.NSPasteboard:generalPasteboard()
	if format == 'text' then
		local data = pasteboard:dataForType(objc.NSStringPboardType)
		return data and objc.tolua(objc.NSString:alloc():initWithUTF8String(data:bytes()))
	elseif format == 'files' then
		local data = pasteboard:propertyListForType(objc.NSFilenamesPboardType)
		return data and objc.tolua(data)
	elseif format == 'bitmap' then
		local image = objc.NSImage:alloc():initWithPasteboard(pasteboard)
		if not image then return end
		return nsimage_to_bitmap(image)
	end
end

function app:set_clipboard(items)
	local pasteboard = objc.NSPasteboard:generalPasteboard()

	--clear the clipboard
	pasteboard:clearContents()
	if not items then return true end

	for i,item in ipairs(items) do
		local data, format = item.data, item.format
		if format == 'text' then
			local nsdata = objc.NSData:dataWithBytes_length(data, #data + 1)
			return pasteboard:setData_forType(nsdata, objc.NSStringPboardType)
		elseif format == 'files' then
			return pasteboard:setPropertyList_forType(objc.toobj(data), objc.NSFilenamesPboardType)
		elseif format == 'bitmap' then
			local image = bitmap_to_nsimage(data)
			local ok = pasteboard:writeObjects{image}
			image:release()
			return ok
		else
			assert(false) --invalid args from frontend
		end
	end
end

--drag & drop ----------------------------------------------------------------

function window:_init_drop()
	self.nswin:registerForDraggedTypes{objc.NSFilenamesPboardType}
end

function Window:draggingEntered(sender) --NSDraggingInfo
	local sourceDragMask = sender:draggingSourceOperationMask() --NSDragOperation
	local pboard = sender:draggingPasteboard() --NSPasteboard

	if pboard:types():containsObject(objc.NSFilenamesPboardType) then
		if bit.band(sourceDragMask, objc.NSDragOperationLink) then
			return objc.NSDragOperationLink
		elseif bit.band(sourceDragMask, objc.NSDragOperationCopy) then
			return objc.NSDragOperationCopy
		end
	end
	return obkc.NSDragOperationNone
end

function Window:prepareForDragOperation(sender)
	return true
end

--function Window:draggingUpdated() end

function Window:performDragOperation(sender)
	--[[
	local sourceDragMask = sender:draggingSourceOperationMask() --NSDragOperation
	local pboard = sender:draggingPasteboard() --NSPasteboard

	if pboard:types():containsObject(objc.NSFilenamesPboardType) then
		if bit.band(sourceDragMask, objc.NSDragOperationLink) then
			return objc.NSDragOperationLink
		elseif bit.band(sourceDragMask, objc.NSDragOperationCopy) then
			return objc.NSDragOperationCopy
		end
	end
	return obkc.NSDragOperationNone
	]]
	return true
end

--buttons --------------------------------------------------------------------



objc.debug.cbframe = _cbframe --restore cbframe setting.

if not ... then require'nw_test' end

return nw
