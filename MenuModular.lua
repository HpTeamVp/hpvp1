--!nonstrict
--[[
	HpTeamProMenu (LocalScript - FILE ĐẦY ĐỦ, chỉ cần dán 1 file)
	Vị trí: StarterPlayer > StarterPlayerScripts > LocalScript (tên bất kỳ)

	=== API NHANH ===
	-- (Trong file này UIController đã nằm sẵn bên dưới, không cần require)
	local ui = UIController.new({
		Title = "Hp Team Pro V1",        -- tiêu đề
		Size = Vector2.new(350, 200),    -- kích thước khi mở rộng
		Position = Vector2.new(24, 80),  -- vị trí ban đầu (pixel)
		Tabs = { "Main", "Esp", "Khác" },-- danh sách tab
		ToggleKey = Enum.KeyCode.RightShift, -- (tuỳ chọn) phím ẩn/hiện trên PC
	})

	Thêm điều khiển:
	ui:AddSection(tab, text)
	ui:AddToggle(tab, { Id, Text, Default, Callback(state) })
	ui:AddNumber(tab, { Id, Text, Min, Max, Step, Default, Decimals, Callback(value) })
	ui:AddButton(tab, { Text, Callback() })

	Đọc / ghi từ module khác:
	ui:GetValue(id)                      -- bool (toggle) hoặc number
	ui:SetValue(id, value, fireEvent)    -- cập nhật từ bên ngoài (mặc định KHÔNG bắn event)
	ui:GetControl(id)                    -- handle: :Get() :Set(v, fire) .Changed:Connect(fn)
	ui:GetState()                        -- { Toggles = {...}, Numbers = {...} }

	Sự kiện: ui.ToggleChanged(id, state) | ui.NumberChanged(id, value)
	         ui.TabChanged(name) | ui.CollapsedChanged(collapsed) | ui.Closed()

	Điều khiển cửa sổ: ui:SelectTab(name) | ui:SetCollapsed(bool) | ui:SetVisible(bool) | ui:Destroy()
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

----------------------------------------------------------------------
-- HẰNG SỐ & GIAO DIỆN
----------------------------------------------------------------------
local TITLE_HEIGHT = 30
local TAB_HEIGHT = 26
local DEFAULT_SIZE = Vector2.new(350, 200)
local DEFAULT_TABS = { "Main", "Esp", "Khác" }

local THEME = {
	Background = Color3.fromHex("0C0E0C"),
	Panel = Color3.fromHex("141814"),
	PanelStroke = Color3.fromHex("1F2B1F"),
	Accent = Color3.fromHex("00FF66"),
	AccentDim = Color3.fromHex("0F3D22"),
	Text = Color3.fromHex("DCE8DC"),
	TextMuted = Color3.fromHex("86998A"),
	OffBadge = Color3.fromHex("3A1A1A"),
	OffText = Color3.fromHex("FF6B6B"),
	Track = Color3.fromHex("26302A"),
	Knob = Color3.fromHex("F2FFF6"),
}

----------------------------------------------------------------------
-- HÀM TIỆN ÍCH TẠO GUI
----------------------------------------------------------------------
-- Tạo Instance, gán thuộc tính, Parent gán sau cùng để tối ưu.
local function create(className, props, parent)
	local instance = Instance.new(className)
	for key, value in pairs(props) do
		instance[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function merge(defaults, overrides)
	for key, value in pairs(overrides) do
		defaults[key] = value
	end
	return defaults
end

local function newLabel(props, parent)
	return create("TextLabel", merge({
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		TextSize = 13,
		TextColor3 = THEME.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}, props), parent)
end

local function newButton(props, parent)
	return create("TextButton", merge({
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = THEME.Text,
		Text = "",
	}, props), parent)
end

local function addCorner(instance, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) }, instance)
end

-- Lưu ý: với TextButton/TextBox phải ép ApplyStrokeMode = Border, nếu không stroke sẽ viền chữ.
local function addStroke(instance, color, thickness, transparency)
	return create("UIStroke", {
		Color = color,
		Thickness = thickness,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, instance)
end

local function tween(instance, props, duration)
	local info = TweenInfo.new(duration or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local t = TweenService:Create(instance, info, props)
	t:Play()
	return t
end

local function applyProps(instance, props, instant)
	if instant then
		for key, value in pairs(props) do
			instance[key] = value
		end
	else
		tween(instance, props)
	end
end

----------------------------------------------------------------------
-- HÀM TIỆN ÍCH SỐ (validate / làm tròn / định dạng)
----------------------------------------------------------------------
-- Đếm số chữ số thập phân của bước nhảy (0.25 -> 2, 1 -> 0).
local function countDecimals(n)
	local s = string.format("%.6f", n)
	s = string.gsub(s, "0+$", "")
	local fraction = string.match(s, "%.(%d*)$") or ""
	return #fraction
end

local function formatNumber(value, decimals)
	return string.format("%." .. tostring(decimals) .. "f", value)
end

-- Chỉ chấp nhận dạng số thuần: "12", "-3.5", ".5", "7,5". Từ chối chữ, hex, 1e3...
local function parseNumberText(text)
	local cleaned = string.gsub(text, "%s", "")
	cleaned = string.gsub(cleaned, ",", ".")
	if string.match(cleaned, "^[-+]?%d+%.?%d*$") or string.match(cleaned, "^[-+]?%.%d+$") then
		return tonumber(cleaned)
	end
	return nil
end

----------------------------------------------------------------------
-- SIGNAL NHẸ (không phụ thuộc BindableEvent)
----------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _connections = {}, _destroyed = false }, Signal)
end

function Signal:Connect(callback)
	assert(type(callback) == "function", "[Signal] Connect cần một function")
	local signal = self
	local connection = { Connected = not self._destroyed, _callback = callback }

	function connection:Disconnect()
		self.Connected = false
		signal._connections[self] = nil
	end

	if connection.Connected then
		self._connections[connection] = true
	end
	return connection
end

function Signal:Fire(...)
	-- Chụp danh sách trước để Disconnect trong lúc Fire vẫn an toàn.
	local snapshot = {}
	for connection in pairs(self._connections) do
		table.insert(snapshot, connection)
	end
	for _, connection in ipairs(snapshot) do
		if connection.Connected then
			task.spawn(connection._callback, ...) -- lỗi ở 1 handler không làm hỏng handler khác
		end
	end
end

function Signal:Destroy()
	self._destroyed = true
	for connection in pairs(self._connections) do
		connection.Connected = false
	end
	table.clear(self._connections)
end

----------------------------------------------------------------------
-- UICONTROLLER
----------------------------------------------------------------------
local UIController = {}
UIController.__index = UIController

local SIGNAL_NAMES = { "ToggleChanged", "NumberChanged", "TabChanged", "CollapsedChanged", "Closed" }

function UIController.new(options)
	options = options or {}
	assert(Players.LocalPlayer, "[UIController] Chỉ chạy được ở phía Client")

	local self = setmetatable({}, UIController)

	self._connections = {} -- mọi kết nối được gom lại để ngắt sạch khi Destroy
	self._tabs = {}
	self._tabOrder = {}
	self._controls = {}
	self._layoutCounter = 0
	self._collapsed = false
	self._destroyed = false
	self._capture = nil -- thao tác con trỏ đang giữ (kéo cửa sổ / kéo slider)
	self._activeTab = nil
	self._sizeTween = nil

	for _, name in ipairs(SIGNAL_NAMES) do
		self[name] = Signal.new()
	end

	local size = options.Size or DEFAULT_SIZE
	self._expandedSize = Vector2.new(size.X, size.Y)

	self:_buildGui(options)
	self:_bindGlobalInput(options)

	for _, tabName in ipairs(options.Tabs or DEFAULT_TABS) do
		self:AddTab(tabName)
	end

	return self
end

----------------------------------------------------------------------
-- NỘI BỘ: DỰNG KHUNG GIAO DIỆN
----------------------------------------------------------------------
function UIController:_connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(self._connections, connection)
	return connection
end

function UIController:_nextOrder()
	self._layoutCounter += 1
	return self._layoutCounter
end

function UIController:_buildGui(options)
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local guiName = options.Name or "HpTeamProMenu"

	-- Xoá menu cũ (nếu script chạy lại) để tránh trùng lặp.
	local old = playerGui:FindFirstChild(guiName)
	if old then
		old:Destroy()
	end

	-- ResetOnSpawn = false: menu không bị tạo lại mỗi khi nhân vật hồi sinh.
	local screenGui = create("ScreenGui", {
		Name = guiName,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = options.DisplayOrder or 100,
		IgnoreGuiInset = true,
	})
	self._screenGui = screenGui

	local startPosition = options.Position or Vector2.new(24, 80)
	local size = self._expandedSize

	-- Root: khung vị trí/kích thước, chứa bóng đổ + cửa sổ.
	local root = create("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(startPosition.X, startPosition.Y),
		Size = UDim2.fromOffset(size.X, size.Y),
	}, screenGui)
	self._root = root

	-- Bóng đổ nhẹ (frame đen mờ lệch xuống dưới).
	local shadow = create("Frame", {
		Name = "Shadow",
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(-2, 2),
		Size = UDim2.new(1, 4, 1, 4),
		ZIndex = 1,
	}, root)
	addCorner(shadow, 10)

	local window = create("Frame", {
		Name = "Window",
		BackgroundColor3 = THEME.Background,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		ZIndex = 2,
	}, root)
	addCorner(window, 8)
	addStroke(window, THEME.Accent, 1.5, 0.1)

	-- ===== Thanh tiêu đề =====
	local titleBar = create("Frame", {
		Name = "TitleBar",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, TITLE_HEIGHT),
	}, window)

	-- Vùng kéo thả (không phủ lên 2 nút bên phải để nút vẫn bấm được).
	local dragArea = newButton({
		Name = "DragArea",
		Size = UDim2.new(1, -64, 1, 0),
	}, titleBar)
	newLabel({
		Name = "Title",
		Text = options.Title or "Hp Team Pro V1",
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = THEME.Accent,
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -10, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, dragArea)

	local collapseButton = newButton({
		Name = "CollapseButton",
		Text = "-",
		TextSize = 18,
		TextColor3 = THEME.Accent,
		BackgroundTransparency = 0,
		BackgroundColor3 = THEME.Panel,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -34, 0.5, 0),
		Size = UDim2.fromOffset(24, 22),
	}, titleBar)
	addCorner(collapseButton, 5)
	self._collapseButton = collapseButton

	local closeButton = newButton({
		Name = "CloseButton",
		Text = "X",
		TextSize = 13,
		TextColor3 = THEME.OffText,
		BackgroundTransparency = 0,
		BackgroundColor3 = THEME.Panel,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(24, 22),
	}, titleBar)
	addCorner(closeButton, 5)

	create("Frame", {
		Name = "Separator",
		BackgroundColor3 = THEME.Accent,
		BackgroundTransparency = 0.7,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, TITLE_HEIGHT),
		Size = UDim2.new(1, 0, 0, 1),
	}, window)

	-- ===== Thân menu: thanh tab + các trang =====
	local body = create("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, TITLE_HEIGHT + 1),
		Size = UDim2.new(1, 0, 1, -(TITLE_HEIGHT + 1)),
		ClipsDescendants = true,
	}, window)
	self._body = body

	local tabBar = create("Frame", {
		Name = "TabBar",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(6, 5),
		Size = UDim2.new(1, -12, 0, TAB_HEIGHT),
	}, body)
	self._tabBar = tabBar
	self._tabGrid = create("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		CellPadding = UDim2.fromOffset(4, 0),
		CellSize = UDim2.new(1, 0, 1, 0),
	}, tabBar)

	self._pages = create("Frame", {
		Name = "Pages",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, TAB_HEIGHT + 10),
		Size = UDim2.new(1, 0, 1, -(TAB_HEIGHT + 10)),
	}, body)

	-- ===== Sự kiện thanh tiêu đề =====
	-- Kéo thả cửa sổ (chuột + cảm ứng).
	self:_connect(dragArea.InputBegan, function(input)
		local inputType = input.UserInputType
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			return
		end
		local startPointer = Vector2.new(input.Position.X, input.Position.Y)
		local startPosition2 = root.AbsolutePosition
		self:_beginCapture(input, function(position)
			local delta = Vector2.new(position.X, position.Y) - startPointer
			self:_applyPosition(startPosition2 + delta)
		end)
	end)

	self:_connect(collapseButton.Activated, function()
		self:SetCollapsed(not self._collapsed)
	end)

	self:_connect(closeButton.Activated, function()
		self.Closed:Fire()
		self:Destroy()
	end)

	-- Nếu kích thước màn hình đổi (xoay máy...), giữ menu trong màn hình.
	self:_connect(screenGui:GetPropertyChangedSignal("AbsoluteSize"), function()
		self:_applyPosition(root.AbsolutePosition)
	end)

	screenGui.Parent = playerGui
end

----------------------------------------------------------------------
-- NỘI BỘ: VỊ TRÍ & CON TRỎ
----------------------------------------------------------------------
-- Giới hạn vị trí để thanh tiêu đề luôn còn nằm trong màn hình.
function UIController:_clampPosition(position)
	local viewport = self._screenGui.AbsoluteSize
	local size = self._root.AbsoluteSize
	local minVisible = 60
	local x = math.clamp(position.X, -(size.X - minVisible), math.max(viewport.X - minVisible, 0))
	local y = math.clamp(position.Y, 0, math.max(viewport.Y - TITLE_HEIGHT, 0))
	return Vector2.new(x, y)
end

function UIController:_applyPosition(position)
	local clamped = self:_clampPosition(position)
	self._root.Position = UDim2.fromOffset(clamped.X, clamped.Y)
end

-- Giữ "con trỏ" cho một thao tác kéo (cửa sổ hoặc slider) cho tới khi nhả.
function UIController:_beginCapture(input, onMove, onEnd)
	self:_endCapture()
	local capture = { Input = input, OnMove = onMove, OnEnd = onEnd }
	capture.Connection = input.Changed:Connect(function()
		if input.UserInputState == Enum.UserInputState.End and self._capture == capture then
			self:_endCapture()
		end
	end)
	self._capture = capture
end

function UIController:_endCapture()
	local capture = self._capture
	if not capture then
		return
	end
	self._capture = nil
	capture.Connection:Disconnect()
	if capture.OnEnd then
		capture.OnEnd()
	end
end

-- Chỉ 1 kết nối toàn cục cho mọi thao tác kéo -> không phát sinh rò rỉ kết nối.
function UIController:_bindGlobalInput(options)
	self:_connect(UserInputService.InputChanged, function(input)
		local capture = self._capture
		if not capture then
			return
		end
		local isMouseMove = input.UserInputType == Enum.UserInputType.MouseMovement
		if isMouseMove or input == capture.Input then
			capture.OnMove(input.Position)
		end
	end)

	self:_connect(UserInputService.InputEnded, function(input)
		local capture = self._capture
		if not capture then
			return
		end
		local mouseReleased = input.UserInputType == Enum.UserInputType.MouseButton1
			and capture.Input.UserInputType == Enum.UserInputType.MouseButton1
		if input == capture.Input or mouseReleased then
			self:_endCapture()
		end
	end)

	-- Phím tắt ẩn/hiện (PC). Bỏ qua khi đang gõ chữ.
	if options.ToggleKey then
		self:_connect(UserInputService.InputBegan, function(input, processed)
			if not processed and input.KeyCode == options.ToggleKey then
				self:SetVisible(not self._screenGui.Enabled)
			end
		end)
	end
end

----------------------------------------------------------------------
-- CỬA SỔ: THU GỌN / HIỆN / ẨN
----------------------------------------------------------------------
-- Thu gọn về thanh tiêu đề, giữ nguyên vị trí hiện tại (Root không đổi Position).
function UIController:SetCollapsed(collapsed)
	collapsed = collapsed == true
	if self._destroyed or collapsed == self._collapsed then
		return
	end
	self._collapsed = collapsed
	self._collapseButton.Text = collapsed and "+" or "-"

	if self._sizeTween then
		self._sizeTween:Cancel()
	end

	local width = self._expandedSize.X
	if collapsed then
		self._sizeTween = tween(self._root, { Size = UDim2.fromOffset(width, TITLE_HEIGHT + 1) }, 0.2)
		task.delay(0.2, function()
			-- Chỉ ẩn thân menu nếu trong lúc chờ người dùng chưa mở lại.
			if self._collapsed and not self._destroyed then
				self._body.Visible = false
			end
		end)
	else
		self._body.Visible = true
		self._sizeTween = tween(self._root, { Size = UDim2.fromOffset(width, self._expandedSize.Y) }, 0.2)
	end

	self.CollapsedChanged:Fire(collapsed)
end

function UIController:IsCollapsed()
	return self._collapsed
end

function UIController:SetVisible(visible)
	if not self._destroyed then
		self._screenGui.Enabled = visible == true
	end
end

function UIController:IsVisible()
	return not self._destroyed and self._screenGui.Enabled
end

----------------------------------------------------------------------
-- TAB
----------------------------------------------------------------------
-- Cập nhật độ rộng ô tab để N tab luôn chia đều chiều ngang.
function UIController:_updateTabLayout()
	local count = math.max(#self._tabOrder, 1)
	local gapShare = math.ceil(4 * (count - 1) / count)
	self._tabGrid.CellSize = UDim2.new(1 / count, -gapShare, 1, 0)
end

function UIController:_styleTab(tab, active, instant)
	applyProps(tab.Button, {
		BackgroundColor3 = active and THEME.AccentDim or THEME.Panel,
		TextColor3 = active and THEME.Accent or THEME.TextMuted,
	}, instant)
	applyProps(tab.Indicator, { BackgroundTransparency = active and 0 or 1 }, instant)
end

function UIController:AddTab(name)
	assert(type(name) == "string" and name ~= "", "[UIController] Tên tab phải là chuỗi không rỗng")
	if self._tabs[name] then
		return self._tabs[name]
	end

	local tabButton = newButton({
		Name = "Tab_" .. name,
		Text = name,
		BackgroundTransparency = 0,
		BackgroundColor3 = THEME.Panel,
		TextColor3 = THEME.TextMuted,
		LayoutOrder = #self._tabOrder + 1,
	}, self._tabBar)
	addCorner(tabButton, 6)

	local indicator = create("Frame", {
		Name = "Indicator",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.new(0.6, 0, 0, 2),
		BackgroundColor3 = THEME.Accent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
	}, tabButton)
	addCorner(indicator, 1)

	-- CanvasGroup cho phép làm mờ (fade) cả trang khi chuyển tab.
	local page = create("CanvasGroup", {
		Name = "Page_" .. name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	}, self._pages)

	-- ScrollingFrame tự căn CanvasSize theo nội dung (AutomaticCanvasSize).
	local scroll = create("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = THEME.Accent,
		ScrollBarImageTransparency = 0.3,
	}, page)
	create("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	}, scroll)
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 6),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 2),
		PaddingBottom = UDim.new(0, 8),
	}, scroll)

	local tab = { Name = name, Button = tabButton, Indicator = indicator, Page = page, Scroll = scroll }
	self._tabs[name] = tab
	table.insert(self._tabOrder, name)
	self:_updateTabLayout()
	self:_styleTab(tab, false, true)

	self:_connect(tabButton.Activated, function()
		self:SelectTab(name)
	end)

	if not self._activeTab then
		self:SelectTab(name, true)
	end
	return tab
end

function UIController:SelectTab(name, instant)
	local tab = self._tabs[name]
	if self._destroyed or not tab or tab == self._activeTab then
		return
	end

	local previous = self._activeTab
	if previous then
		previous.Page.Visible = false
		self:_styleTab(previous, false, instant == true)
	end

	self._activeTab = tab
	tab.Page.Visible = true
	self:_styleTab(tab, true, instant == true)

	if instant then
		tab.Page.GroupTransparency = 0
	else
		tab.Page.GroupTransparency = 1
		tween(tab.Page, { GroupTransparency = 0 }, 0.2)
	end

	self.TabChanged:Fire(name)
end

function UIController:GetActiveTab()
	return self._activeTab and self._activeTab.Name or nil
end

function UIController:_requireTab(name)
	local tab = self._tabs[name]
	if not tab then
		error(string.format("[UIController] Tab '%s' không tồn tại", tostring(name)), 3)
	end
	return tab
end

function UIController:_reserveId(id)
	assert(type(id) == "string" and id ~= "", "[UIController] Control cần có Id dạng chuỗi")
	assert(self._controls[id] == nil, string.format("[UIController] Id '%s' đã tồn tại", id))
	return id
end

----------------------------------------------------------------------
-- ĐIỀU KHIỂN: SECTION / BUTTON
----------------------------------------------------------------------
function UIController:AddSection(tabName, text)
	local tab = self:_requireTab(tabName)
	return newLabel({
		Name = "Section",
		Text = string.upper(text or ""),
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = THEME.Accent,
		Size = UDim2.new(1, 0, 0, 18),
		LayoutOrder = self:_nextOrder(),
	}, tab.Scroll)
end

function UIController:AddButton(tabName, options)
	local tab = self:_requireTab(tabName)
	local row = newButton({
		Name = "Button_" .. tostring(options.Id or options.Text or "Button"),
		Text = options.Text or "Button",
		TextColor3 = THEME.Accent,
		BackgroundTransparency = 0,
		BackgroundColor3 = THEME.AccentDim,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = self:_nextOrder(),
	}, tab.Scroll)
	addCorner(row, 6)
	addStroke(row, THEME.Accent, 1, 0.6)

	self:_connect(row.Activated, function()
		if options.Callback then
			task.spawn(options.Callback)
		end
	end)
	return row
end

----------------------------------------------------------------------
-- ĐIỀU KHIỂN: TOGGLE ON/OFF
----------------------------------------------------------------------
function UIController:AddToggle(tabName, options)
	assert(type(options) == "table", "[UIController] AddToggle cần bảng options")
	local tab = self:_requireTab(tabName)
	local id = self:_reserveId(options.Id)
	local state = options.Default == true

	-- Cả hàng là một nút bấm; huy hiệu bên phải hiển thị ON / OFF.
	local row = newButton({
		Name = "Toggle_" .. id,
		BackgroundTransparency = 0,
		BackgroundColor3 = THEME.Panel,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = self:_nextOrder(),
	}, tab.Scroll)
	addCorner(row, 6)
	local rowStroke = addStroke(row, THEME.PanelStroke, 1, 0)

	newLabel({
		Name = "Label",
		Text = options.Text or id,
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -72, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, row)

	local badge = create("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(46, 20),
		BorderSizePixel = 0,
	}, row)
	addCorner(badge, 10)
	local badgeText = newLabel({
		Name = "State",
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromScale(1, 1),
	}, badge)

	local handle = { Id = id, Type = "Toggle", Instance = row, Changed = Signal.new() }

	local function render(instant)
		badgeText.Text = state and "ON" or "OFF"
		applyProps(badge, { BackgroundColor3 = state and THEME.Accent or THEME.OffBadge }, instant)
		applyProps(badgeText, { TextColor3 = state and THEME.Background or THEME.OffText }, instant)
		applyProps(rowStroke, { Color = state and THEME.Accent or THEME.PanelStroke }, instant)
	end

	local function setState(newState, fireEvent)
		newState = newState == true
		if newState == state then
			return
		end
		state = newState
		render(false)
		if fireEvent then
			if options.Callback then
				task.spawn(options.Callback, state)
			end
			handle.Changed:Fire(state)
			self.ToggleChanged:Fire(id, state)
		end
	end

	function handle:Get()
		return state
	end

	-- Cập nhật từ bên ngoài: mặc định KHÔNG bắn callback (tránh vòng lặp). Truyền fireEvent = true nếu muốn.
	function handle:Set(newState, fireEvent)
		setState(newState, fireEvent == true)
	end

	render(true)
	self:_connect(row.Activated, function()
		setState(not state, true)
	end)

	self._controls[id] = handle
	return handle
end

----------------------------------------------------------------------
-- ĐIỀU KHIỂN: SỐ (nhập trực tiếp + nút -/+ + slider)
----------------------------------------------------------------------
function UIController:AddNumber(tabName, options)
	assert(type(options) == "table", "[UIController] AddNumber cần bảng options")
	local tab = self:_requireTab(tabName)
	local id = self:_reserveId(options.Id)

	local minValue = options.Min or 0
	local maxValue = options.Max or 100
	local step = options.Step or 1
	assert(maxValue > minValue, "[UIController] Max phải lớn hơn Min")
	assert(step > 0, "[UIController] Step phải > 0")
	local decimals = options.Decimals or countDecimals(step)

	-- Validate: loại bỏ nil/NaN/inf, ép về [Min, Max] và làm tròn theo Step.
	local function normalize(raw)
		local n = tonumber(raw)
		if n == nil or n ~= n or n == math.huge or n == -math.huge then
			return nil
		end
		n = math.clamp(n, minValue, maxValue)
		n = minValue + math.floor((n - minValue) / step + 0.5) * step
		n = math.clamp(n, minValue, maxValue)
		return tonumber(string.format("%." .. tostring(decimals) .. "f", n))
	end

	local current = normalize(options.Default) or minValue

	-- ===== Dựng giao diện =====
	local row = create("Frame", {
		Name = "Number_" .. id,
		BackgroundColor3 = THEME.Panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 58),
		LayoutOrder = self:_nextOrder(),
	}, tab.Scroll)
	addCorner(row, 6)
	addStroke(row, THEME.PanelStroke, 1, 0)

	newLabel({
		Name = "Label",
		Text = options.Text or id,
		Position = UDim2.fromOffset(10, 5),
		Size = UDim2.new(1, -88, 0, 20),
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, row)

	local input = create("TextBox", {
		Name = "Input",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 5),
		Size = UDim2.fromOffset(64, 20),
		BackgroundColor3 = THEME.Background,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = THEME.Accent,
		Text = "",
	}, row)
	addCorner(input, 5)
	addStroke(input, THEME.PanelStroke, 1, 0)

	local minusButton = newButton({
		Name = "Minus",
		Text = "-",
		TextSize = 16,
		TextColor3 = THEME.Accent,
		BackgroundTransparency = 0,
		BackgroundColor3 = THEME.Background,
		Position = UDim2.fromOffset(8, 32),
		Size = UDim2.fromOffset(24, 20),
	}, row)
	addCorner(minusButton, 5)

	local plusButton = newButton({
		Name = "Plus",
		Text = "+",
		TextSize = 16,
		TextColor3 = THEME.Accent,
		BackgroundTransparency = 0,
		BackgroundColor3 = THEME.Background,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 32),
		Size = UDim2.fromOffset(24, 20),
	}, row)
	addCorner(plusButton, 5)

	-- Vùng bấm/kéo slider (cao hơn đường track để dễ chạm trên mobile).
	local hitArea = newButton({
		Name = "SliderHit",
		Position = UDim2.fromOffset(40, 32),
		Size = UDim2.new(1, -80, 0, 20),
	}, row)
	local track = create("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 7, 0.5, 0),
		Size = UDim2.new(1, -14, 0, 6),
		BackgroundColor3 = THEME.Track,
		BorderSizePixel = 0,
	}, hitArea)
	addCorner(track, 3)
	local fill = create("Frame", {
		Name = "Fill",
		BackgroundColor3 = THEME.Accent,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
	}, track)
	addCorner(fill, 3)
	local knob = create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = THEME.Knob,
		BorderSizePixel = 0,
	}, track)
	addCorner(knob, 7)
	addStroke(knob, THEME.Accent, 1.5, 0)

	-- ===== Logic =====
	local handle = { Id = id, Type = "Number", Instance = row, Changed = Signal.new() }

	local function refresh()
		local alpha = (current - minValue) / (maxValue - minValue)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		input.Text = formatNumber(current, decimals)
	end

	-- Trả về true nếu giá trị thật sự thay đổi. Giá trị không hợp lệ -> khôi phục giá trị cũ.
	local function setValue(raw, fireEvent)
		local normalized = normalize(raw)
		if normalized == nil then
			refresh()
			return false
		end
		local changed = normalized ~= current
		current = normalized
		refresh()
		if changed and fireEvent then
			if options.Callback then
				task.spawn(options.Callback, current)
			end
			handle.Changed:Fire(current)
			self.NumberChanged:Fire(id, current)
		end
		return changed
	end

	function handle:Get()
		return current
	end

	function handle:Set(value, fireEvent)
		return setValue(value, fireEvent == true)
	end

	-- Đổi giới hạn lúc chạy (vd: Max phụ thuộc tính năng khác); giá trị hiện tại tự được ép lại.
	function handle:SetRange(newMin, newMax)
		assert(type(newMin) == "number" and type(newMax) == "number" and newMax > newMin, "[UIController] Range không hợp lệ")
		minValue, maxValue = newMin, newMax
		setValue(current, true)
		refresh()
	end

	-- Chặn ký tự lạ ngay khi gõ; kiểm tra đầy đủ khi rời ô nhập.
	self:_connect(input:GetPropertyChangedSignal("Text"), function()
		if input:IsFocused() then
			local cleaned = string.gsub(input.Text, "[^%d%.%-%+,]", "")
			if cleaned ~= input.Text then
				input.Text = cleaned
			end
		end
	end)
	self:_connect(input.FocusLost, function()
		setValue(parseNumberText(input.Text), true)
	end)

	self:_connect(minusButton.Activated, function()
		setValue(current - step, true)
	end)
	self:_connect(plusButton.Activated, function()
		setValue(current + step, true)
	end)

	-- Kéo slider: tạm khoá cuộn của ScrollingFrame để vuốt ngang không bị giật cuộn dọc.
	self:_connect(hitArea.InputBegan, function(inputObject)
		local inputType = inputObject.UserInputType
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			return
		end
		local function updateFromPointer(position)
			local width = math.max(track.AbsoluteSize.X, 1)
			local alpha = math.clamp((position.X - track.AbsolutePosition.X) / width, 0, 1)
			setValue(minValue + alpha * (maxValue - minValue), true)
		end
		tab.Scroll.ScrollingEnabled = false
		updateFromPointer(inputObject.Position)
		self:_beginCapture(inputObject, updateFromPointer, function()
			tab.Scroll.ScrollingEnabled = true
		end)
	end)

	refresh()
	self._controls[id] = handle
	return handle
end

----------------------------------------------------------------------
-- TRUY CẬP TỪ MODULE KHÁC
----------------------------------------------------------------------
function UIController:GetControl(id)
	return self._controls[id]
end

function UIController:GetValue(id)
	local control = self._controls[id]
	if control then
		return control:Get()
	end
	return nil
end

-- Cập nhật giá trị từ bên ngoài. fireEvent mặc định false.
function UIController:SetValue(id, value, fireEvent)
	local control = self._controls[id]
	assert(control, string.format("[UIController] Không tìm thấy control '%s'", tostring(id)))
	control:Set(value, fireEvent)
end

-- Ảnh chụp toàn bộ trạng thái hiện tại (tiện lưu/đồng bộ cấu hình).
function UIController:GetState()
	local state = { Toggles = {}, Numbers = {} }
	for id, control in pairs(self._controls) do
		if control.Type == "Toggle" then
			state.Toggles[id] = control:Get()
		elseif control.Type == "Number" then
			state.Numbers[id] = control:Get()
		end
	end
	return state
end

----------------------------------------------------------------------
-- DỌN DẸP
----------------------------------------------------------------------
function UIController:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	self:_endCapture()
	if self._sizeTween then
		self._sizeTween:Cancel()
	end

	-- Ngắt toàn bộ kết nối (kể cả kết nối UserInputService) để không rò rỉ.
	for _, connection in ipairs(self._connections) do
		connection:Disconnect()
	end
	table.clear(self._connections)

	for _, control in pairs(self._controls) do
		control.Changed:Destroy()
	end
	table.clear(self._controls)

	self._screenGui:Destroy()

	for _, name in ipairs(SIGNAL_NAMES) do
		self[name]:Destroy()
	end
end

--[[
	=== VÍ DỤ SỬ DỤNG (LocalScript) ===
	-- (UIController đã có sẵn trong file này)
	local ui = UIController.new({ Title = "Hp Team Pro V1", ToggleKey = Enum.KeyCode.RightShift })

	ui:AddSection("Main", "Tele Dron")
	ui:AddToggle("Main", {
		Id = "TeleDron", Text = "Tele Dron", Default = false,
		Callback = function(on) print("Tele Dron:", on) end,
	})
	ui:AddNumber("Main", { Id = "TeleDronSafeHeight", Text = "Tele Dron - Khoảng cách an toàn", Min = 2, Max = 50, Step = 1, Default = 10 })

	ui:AddNumber("Khác", { Id = "FlySpeed", Text = "Fly Speed", Min = 1, Max = 300, Step = 1, Default = 50 })
	ui:AddNumber("Khác", { Id = "Speed", Text = "Speed", Min = 16, Max = 200, Step = 1, Default = 16 })

	-- Lắng nghe từ module khác:
	ui.ToggleChanged:Connect(function(id, state) end)
	ui.NumberChanged:Connect(function(id, value) end)

	-- Đọc / ghi từ bên ngoài:
	local flySpeed = ui:GetValue("FlySpeed")
	ui:SetValue("TeleDron", false) -- ép tắt, không bắn callback
]]

----------------------------------------------------------------------
-- KHỞI TẠO MENU (phần chạy thật)
----------------------------------------------------------------------
local ui = UIController.new({
	Title = "Hp Team Pro V1",
	Size = Vector2.new(350, 200),
	Position = Vector2.new(24, 80),
	ToggleKey = Enum.KeyCode.RightShift, -- PC: ẩn/hiện menu
})

-- Cho script khác truy cập: _G.HpTeamProUI:GetValue("FlySpeed")
_G.HpTeamProUI = ui

-- ===== TAB MAIN =====
ui:AddSection("Main", "Tele Dron")
ui:AddToggle("Main", {
	Id = "TeleDron",
	Text = "Tele Dron",
	Default = false,
	Callback = function(on)
		-- Cắm logic Tele Dron của bạn vào đây
		print("[Menu] Tele Dron:", on)
	end,
})
ui:AddNumber("Main", {
	Id = "TeleDronSafeHeight",
	Text = "Khoảng cách an toàn (studs)",
	Min = 2,
	Max = 50,
	Step = 1,
	Default = 10,
})

-- ===== TAB ESP =====
ui:AddSection("Esp", "Chưa có chức năng")
-- Thêm bằng: ui:AddToggle("Esp", { Id = "...", Text = "...", Callback = function(on) end })

-- ===== TAB KHÁC =====
ui:AddSection("Khác", "Di chuyển")
ui:AddToggle("Khác", {
	Id = "FlyAir",
	Text = "Fly Air",
	Default = false,
	Callback = function(on)
		print("[Menu] Fly Air:", on)
	end,
})
ui:AddNumber("Khác", {
	Id = "FlySpeed",
	Text = "Fly Speed",
	Min = 1,
	Max = 300,
	Step = 1,
	Default = 50,
})
ui:AddNumber("Khác", {
	Id = "Speed",
	Text = "Speed (WalkSpeed)",
	Min = 16,
	Max = 200,
	Step = 1,
	Default = 16,
})

-- Lắng nghe chung mọi thay đổi (để kết nối module chức năng)
ui.ToggleChanged:Connect(function(id, state)
	print("[Menu] Toggle", id, "=", state)
end)
ui.NumberChanged:Connect(function(id, value)
	print("[Menu] Number", id, "=", value)
end)
