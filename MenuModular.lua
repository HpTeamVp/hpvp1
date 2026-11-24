--[[
	DEBUG / TEST PANEL (LocalScript) - 3 tab: Main | Esp | Khác
	Đặt vào StarterPlayer > StarterPlayerScripts (dùng để test trong game của bạn / Studio).
	Cấu trúc: StateManager, TargetScanner, CombatEngine, EspEngine, MovementAndWorld, UIController.

	LƯU Ý QUAN TRỌNG:
	- Script chạy phía client. Thay đổi lên Model của mob (kích thước, vị trí, Anchored...) chỉ có tác dụng
	  cục bộ; sát thương / AI / tấn công mob luôn do SERVER quyết định. Muốn chặn mob đánh người chơi,
	  hoặc nhận sát thương theo hitbox mở rộng thật sự thì phải làm thêm phía server (RemoteEvent kiểm tra).
	- Cắm cơ chế đánh của game vào: CombatEngine.AttackHook(target, mode)  (xem phần CombatEngine).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local LP = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

---------------------------------------------------------------------
-- Tiện ích chung
---------------------------------------------------------------------
local function getChar()
	local ch = LP.Character
	if not ch then return end
	local hum = ch:FindFirstChildOfClass("Humanoid")
	local root = ch:FindFirstChild("HumanoidRootPart")
	if hum and root and hum.Health > 0 then return ch, hum, root end
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

---------------------------------------------------------------------
-- 1) StateManager: cờ bật/tắt, cấu hình, snapshot, janitor chống rò rỉ kết nối
---------------------------------------------------------------------
local State = {
	Config = {
		ScanRange = 150, SafeHeight = 12, FlySpeed = 60, WalkSpeed = 16,
		DroneHeight = 6, DownDepth = 8, HitboxSize = 15, UndergroundDepth = 30,
		HeadDepth = 6, LongLegs = 40, BarrierRadius = 12, AimSmooth = 0.35,
		AttackInterval = 0.15,
	},
	Flags = {},      -- [tên] = bool
	Handlers = {},   -- [tên] = {start=fn, stop=fn}
	Snap = {},       -- [tên] = bảng giá trị gốc
	Janitors = {},
	OnChanged = {},  -- callback UI
}

-- Janitor: gom kết nối/Instance/hàm để dọn sạch khi tắt tính năng
local function newJanitor()
	local j = { items = {} }
	function j:Add(x) table.insert(self.items, x) return x end
	function j:Clean()
		for _, x in ipairs(self.items) do
			local t = typeof(x)
			if t == "RBXScriptConnection" then x:Disconnect()
			elseif t == "Instance" then pcall(function() x:Destroy() end)
			elseif t == "function" then pcall(x) end
		end
		table.clear(self.items)
	end
	return j
end

function State.Janitor(name)
	State.Janitors[name] = State.Janitors[name] or newJanitor()
	return State.Janitors[name]
end

function State.Register(name, startFn, stopFn)
	State.Flags[name] = false
	State.Handlers[name] = { start = startFn, stop = stopFn }
end

function State.Set(name, on)
	local h = State.Handlers[name]
	if not h or State.Flags[name] == on then return end
	State.Flags[name] = on
	if on then
		local ok, err = pcall(h.start)
		if not ok then
			warn("[DebugPanel] lỗi bật " .. name .. ": " .. tostring(err))
			State.Flags[name] = false
			pcall(h.stop)
			State.Janitor(name):Clean()
		end
	else
		pcall(h.stop)
		State.Janitor(name):Clean()
	end
	for _, cb in ipairs(State.OnChanged) do pcall(cb, name) end
end

function State.Toggle(name) State.Set(name, not State.Flags[name]) end

---------------------------------------------------------------------
-- 2) TargetScanner: theo dõi Humanoid bằng sự kiện + quét có giới hạn tần suất
---------------------------------------------------------------------
local Scanner = { Humanoids = {}, Targets = {}, _last = 0, Interval = 0.1 }

local function track(inst)
	if inst:IsA("Humanoid") then Scanner.Humanoids[inst] = true end
end
task.spawn(function()
	local n = 0
	for _, d in ipairs(Workspace:GetDescendants()) do
		track(d)
		n += 1
		if n % 2000 == 0 then task.wait() end -- yield để không treo khung hình
	end
end)
Workspace.DescendantAdded:Connect(track)
Workspace.DescendantRemoving:Connect(function(i) Scanner.Humanoids[i] = nil end)

-- Kiểm tra 1 Model còn hợp lệ & trong tầm không. Trả về hum, root, dist
function Scanner.Check(model)
	if not model or not model.Parent then return end
	if model == LP.Character then return end
	if Players:GetPlayerFromCharacter(model) then return end -- bỏ qua người chơi khác
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not root then return end
	local _, _, myRoot = getChar()
	if not myRoot then return end
	local dist = (root.Position - myRoot.Position).Magnitude
	if dist > State.Config.ScanRange then return end
	return hum, root, dist
end

function Scanner.Scan(force)
	local now = os.clock()
	if not force and now - Scanner._last < Scanner.Interval then return Scanner.Targets end
	Scanner._last = now
	local list = {}
	for hum in pairs(Scanner.Humanoids) do
		local model = hum.Parent
		if model and model:IsA("Model") then
			local h, root, dist = Scanner.Check(model)
			if h then table.insert(list, { Model = model, Hum = h, Root = root, Dist = dist }) end
		end
	end
	table.sort(list, function(a, b) return a.Dist < b.Dist end) -- ưu tiên gần nhất
	Scanner.Targets = list
	return list
end

---------------------------------------------------------------------
-- 3) CombatEngine
---------------------------------------------------------------------
local Combat = { Target = nil, _lastAtk = 0 }

--[[ CẮM CƠ CHẾ TẤN CÔNG CỦA GAME TẠI ĐÂY:
	target = {Model, Hum, Root, Dist}; mode = "Dron" | "Kill" | ...
	Ví dụ: ReplicatedStorage.Remotes.Attack:FireServer(target.Model)
	hoặc gọi skill: SkillRemote:FireServer("Slash", target.Root.Position)
	Mặc định: kích hoạt Tool đang cầm. ]]
Combat.AttackHook = function(target, mode)
	local ch = LP.Character
	local tool = ch and ch:FindFirstChildOfClass("Tool")
	if tool then pcall(function() tool:Activate() end) end
end

function Combat.Attack(target, mode)
	local now = os.clock()
	if now - Combat._lastAtk < State.Config.AttackInterval then return end
	Combat._lastAtk = now
	local ok, err = pcall(Combat.AttackHook, target, mode)
	if not ok then warn("[AttackHook] " .. tostring(err)) end
end

-- Khóa mục tiêu tạm thời: giữ mục tiêu tới khi chết / biến mất / ra khỏi 150 mới đổi
function Combat.Lock()
	local t = Combat.Target
	if t then
		local h, root, dist = Scanner.Check(t.Model)
		if h then t.Hum, t.Root, t.Dist = h, root, dist return t end
	end
	Combat.Target = Scanner.Scan(true)[1]
	return Combat.Target
end

local function zeroVel(root)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

-- Tele Dron: lơ lửng phía trên mục tiêu, nhìn xuống và đánh
State.Register("Tele Dron", function()
	local j = State.Janitor("Tele Dron")
	local _, hum = getChar()
	local snap = { PlatformStand = hum and hum.PlatformStand }
	State.Snap["Tele Dron"] = snap
	j:Add(RunService.Heartbeat:Connect(function()
		local ch, h, root = getChar()
		if not ch then return end
		local t = Combat.Lock()
		if not t then return end
		h.PlatformStand = true
		local p = t.Root.Position + Vector3.new(0, State.Config.SafeHeight, 0)
		root.CFrame = CFrame.lookAt(p, t.Root.Position) -- bám theo + nhìn xuống
		zeroVel(root) -- triệt tiêu lực rơi / đẩy lùi
		Combat.Attack(t, "Dron")
	end))
	j:Add(function()
		local _, h = getChar()
		if h and snap.PlatformStand ~= nil then h.PlatformStand = snap.PlatformStand end
	end)
end, function() end)

-- Tele Kill: dịch chuyển tới sau lưng mục tiêu rồi đánh, tự đổi mục tiêu khi chết
State.Register("Tele Kill", function()
	local j = State.Janitor("Tele Kill")
	j:Add(RunService.Heartbeat:Connect(function()
		local ch, _, root = getChar()
		if not ch then return end
		local t = Combat.Lock()
		if not t then return end
		local tcf = t.Root.CFrame
		root.CFrame = CFrame.lookAt((tcf * CFrame.new(0, 0, 4)).Position, t.Root.Position)
		zeroVel(root)
		Combat.Attack(t, "Kill")
	end))
end, function() end)

-- Aimbot: xoay Camera mượt về mục tiêu (lerp chống giật khi đổi mục tiêu)
State.Register("Aimbot", function()
	local j = State.Janitor("Aimbot")
	RunService:BindToRenderStep("DebugPanelAim", Enum.RenderPriority.Camera.Value + 1, function()
		local t = Combat.Lock()
		if not t then return end
		local cam = Workspace.CurrentCamera
		local goal = CFrame.lookAt(cam.CFrame.Position, t.Root.Position)
		cam.CFrame = cam.CFrame:Lerp(goal, State.Config.AimSmooth)
	end)
	j:Add(function() RunService:UnbindFromRenderStep("DebugPanelAim") end)
end, function() end)

-- Hitbox All Mod: phóng to HumanoidRootPart của mob (cục bộ) + vẽ hộp bao
local HB = {}
local function hbRestore(root)
	local s = HB[root]
	if not s then return end
	HB[root] = nil
	if root.Parent then
		root.Size, root.Transparency, root.CanCollide, root.Massless = s.Size, s.Transp, s.Collide, s.Massless
	end
	if s.Box then s.Box:Destroy() end
end
State.Register("Hitbox All Mod", function()
	local j = State.Janitor("Hitbox All Mod")
	j:Add(RunService.Heartbeat:Connect(function()
		local inRange = {}
		for _, t in ipairs(Scanner.Scan()) do
			local r = t.Root
			inRange[r] = true
			local size = State.Config.HitboxSize
			if not HB[r] then
				local box = Instance.new("BoxHandleAdornment")
				box.Adornee, box.AlwaysOnTop, box.ZIndex = r, true, 2
				box.Transparency, box.Color3 = 0.7, Color3.fromRGB(255, 70, 70)
				box.Parent = r
				HB[r] = { Size = r.Size, Transp = r.Transparency, Collide = r.CanCollide, Massless = r.Massless, Box = box }
			end
			-- hộp cao hơn để phủ cả vùng dưới đất; CanCollide=false để xuyên tường/vật cản
			r.Size = Vector3.new(size, size * 1.5, size)
			r.CanCollide, r.Massless, r.Transparency = false, true, 1
			HB[r].Box.Size = r.Size
		end
		for r in pairs(HB) do
			if not inRange[r] or not r.Parent then hbRestore(r) end
		end
	end))
	j:Add(function() for r in pairs(HB) do hbRestore(r) end end)
end, function() end)

-- Điều khiển Model: All Mod Im / Độn Thổ / Head Down (dùng chung snapshot pivot)
local Mods = {}
local function modRestore(model)
	local s = Mods[model]
	if not s then return end
	Mods[model] = nil
	if model.Parent then
		pcall(function() model:PivotTo(s.Pivot) end)
		if s.Root.Parent then s.Root.Anchored = s.Anchored end
		if s.Hum.Parent then s.Hum.WalkSpeed, s.Hum.AutoRotate = s.WalkSpeed, s.AutoRotate end
	end
end
local function modRefresh()
	local F = State.Flags
	local active = F["All Mod Im"] or F["Model Độn Thổ"] or F["Model head down"]
	local inRange = {}
	if active then
		for _, t in ipairs(Scanner.Scan()) do
			local m = t.Model
			inRange[m] = true
			if not Mods[m] then
				Mods[m] = { Pivot = m:GetPivot(), Root = t.Root, Hum = t.Hum, Anchored = t.Root.Anchored,
					WalkSpeed = t.Hum.WalkSpeed, AutoRotate = t.Hum.AutoRotate }
			end
			local s = Mods[m]
			t.Hum.WalkSpeed, t.Hum.AutoRotate = 0, false
			s.Root.Anchored = true -- đứng yên, không xoay
			local cf = s.Pivot
			if F["Model Độn Thổ"] then
				cf = s.Pivot - Vector3.new(0, State.Config.UndergroundDepth, 0)
			elseif F["Model head down"] then
				-- lật ngược (đầu xuống) và hạ thấp để đầu-vai cắm vào đất
				cf = CFrame.new(s.Pivot.Position - Vector3.new(0, State.Config.HeadDepth, 0))
					* s.Pivot.Rotation * CFrame.Angles(math.pi, 0, 0)
			end
			m:PivotTo(cf)
		end
	end
	for m in pairs(Mods) do
		if not inRange[m] then modRestore(m) end
	end
end
local function registerMod(name)
	State.Register(name, function()
		local j = State.Janitor(name)
		j:Add(RunService.Heartbeat:Connect(modRefresh))
		j:Add(function()
			task.defer(function() -- sau khi cờ đã tắt: khôi phục hoặc cập nhật theo cờ còn lại
				local F = State.Flags
				if not (F["All Mod Im"] or F["Model Độn Thổ"] or F["Model head down"]) then
					for m in pairs(Mods) do modRestore(m) end
				end
			end)
		end)
	end, function() end)
end
registerMod("All Mod Im"); registerMod("Model Độn Thổ"); registerMod("Model head down")

-- Player Barrier: vòng rào vô hình quanh người chơi (không va chạm với chính mình)
State.Register("Player Barrier", function()
	local j = State.Janitor("Player Barrier")
	local folder = j:Add(Instance.new("Folder"))
	folder.Name = "PB_Barrier"; folder.Parent = Workspace
	local walls, N = {}, 12
	for i = 1, N do
		local w = Instance.new("Part")
		w.Anchored, w.CanCollide, w.CanQuery, w.Transparency = true, true, false, 1
		w.Size = Vector3.new(2 * State.Config.BarrierRadius * math.tan(math.pi / N) + 1, 16, 1)
		w.Parent = folder
		walls[i] = w
	end
	local linked = {}
	j:Add(RunService.Heartbeat:Connect(function()
		local ch, _, root = getChar()
		if not ch then return end
		for _, d in ipairs(ch:GetDescendants()) do -- không va chạm với thân mình
			if d:IsA("BasePart") and not linked[d] then
				linked[d] = true
				for _, w in ipairs(walls) do
					local c = Instance.new("NoCollisionConstraint")
					c.Part0, c.Part1, c.Parent = d, w, w
				end
			end
		end
		for i, w in ipairs(walls) do
			local a = (i / N) * math.pi * 2
			local off = Vector3.new(math.cos(a), 0, math.sin(a)) * State.Config.BarrierRadius
			w.CFrame = CFrame.lookAt(root.Position + off, root.Position)
		end
	end))
end, function() end)

-- Long Legs: kéo dài chân mob xuống lòng đất (cục bộ) để dễ đánh trúng
local LEG = { LeftLowerLeg = 1, RightLowerLeg = 1, ["Left Leg"] = 1, ["Right Leg"] = 1 }
local Legs = {}
local function legRestore(model)
	local s = Legs[model]
	if not s then return end
	Legs[model] = nil
	for part, size in pairs(s) do if part.Parent then part.Size = size end end
end
State.Register("Long Legs", function()
	local j = State.Janitor("Long Legs")
	j:Add(RunService.Heartbeat:Connect(function()
		local inRange = {}
		for _, t in ipairs(Scanner.Scan()) do
			local m = t.Model
			inRange[m] = true
			if not Legs[m] then
				local s = {}
				for _, p in ipairs(m:GetChildren()) do
					if p:IsA("BasePart") and LEG[p.Name] then s[p] = p.Size end
				end
				Legs[m] = s
			end
			for p, orig in pairs(Legs[m]) do
				if p.Parent then p.Size = Vector3.new(orig.X, orig.Y + State.Config.LongLegs, orig.Z) end
			end
		end
		for m in pairs(Legs) do if not inRange[m] or not m.Parent then legRestore(m) end end
	end))
	j:Add(function() for m in pairs(Legs) do legRestore(m) end end)
end, function() end)

---------------------------------------------------------------------
-- 4) EspEngine: vẽ bằng ScreenGui (an toàn, không cần Drawing API)
---------------------------------------------------------------------
local Esp = { Entries = {}, Gui = nil }

local function makeGui()
	local g = Instance.new("ScreenGui")
	g.Name, g.ResetOnSpawn, g.IgnoreGuiInset, g.DisplayOrder = "DebugPanelEsp", false, true, 5
	g.Parent = LP:WaitForChild("PlayerGui")
	return g
end

local function espDestroyPart(e, key)
	if e[key] then e[key]:Destroy(); e[key] = nil end
end

function Esp.Cleanup(model)
	local e = Esp.Entries[model]
	if not e then return end
	for _, k in ipairs({ "Line", "Box", "Name", "Dist", "Hl" }) do espDestroyPart(e, k) end
	Esp.Entries[model] = nil
end

local function boxCorners(model)
	local cf, size = model:GetBoundingBox()
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for x = -1, 1, 2 do for y = -1, 1, 2 do for z = -1, 1, 2 do
		local v, vis = Camera:WorldToViewportPoint((cf * CFrame.new(size.X / 2 * x, size.Y / 2 * y, size.Z / 2 * z)).Position)
		if v.Z <= 0 then return end -- phía sau camera
		minX, minY = math.min(minX, v.X), math.min(minY, v.Y)
		maxX, maxY = math.max(maxX, v.X), math.max(maxY, v.Y)
	end end end
	return minX, minY, maxX, maxY
end

local function newText()
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency, t.TextColor3, t.TextStrokeTransparency = 1, Color3.new(1, 1, 1), 0
	t.Font, t.TextSize, t.Size, t.AnchorPoint = Enum.Font.GothamBold, 13, UDim2.fromOffset(160, 14), Vector2.new(0.5, 1)
	t.Parent = Esp.Gui
	return t
end

local function espUpdate()
	local F = State.Flags
	local any = F["Esp Line"] or F["Esp Box"] or F["Esp Name"] or F["Esp Distance"] or F["Esp Hologram"]
	if not any then
		for m in pairs(Esp.Entries) do Esp.Cleanup(m) end
		return
	end
	Camera = Workspace.CurrentCamera
	local vp = Camera.ViewportSize
	local seen = {}
	for _, t in ipairs(Scanner.Scan()) do
		local m = t.Model
		seen[m] = true
		local e = Esp.Entries[m]
		if not e then e = {}; Esp.Entries[m] = e end
		local x1, y1, x2, y2 = boxCorners(m)
		local pos, onScreen = Camera:WorldToViewportPoint(t.Root.Position)
		local visible = x1 ~= nil and pos.Z > 0

		-- Line: từ cạnh trên giữa màn hình tới mục tiêu
		if F["Esp Line"] and visible then
			if not e.Line then
				local l = Instance.new("Frame")
				l.BorderSizePixel, l.BackgroundColor3, l.AnchorPoint = 0, Color3.fromRGB(255, 80, 80), Vector2.new(0.5, 0.5)
				l.Parent = Esp.Gui; e.Line = l
			end
			local a, b = Vector2.new(vp.X / 2, 0), Vector2.new(pos.X, pos.Y)
			local d = b - a
			e.Line.Size = UDim2.fromOffset(d.Magnitude, 1)
			e.Line.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
			e.Line.Rotation = math.deg(math.atan2(d.Y, d.X))
		else espDestroyPart(e, "Line") end

		-- Box: khung 2D theo bounding box 3D chiếu lên màn hình
		if F["Esp Box"] and visible then
			if not e.Box then
				local b = Instance.new("Frame")
				b.BackgroundTransparency = 1
				local s = Instance.new("UIStroke"); s.Color, s.Thickness = Color3.fromRGB(80, 255, 120), 1.5; s.Parent = b
				b.Parent = Esp.Gui; e.Box = b
			end
			e.Box.Position = UDim2.fromOffset(x1, y1)
			e.Box.Size = UDim2.fromOffset(x2 - x1, y2 - y1)
		else espDestroyPart(e, "Box") end

		-- Name
		if F["Esp Name"] and visible then
			e.Name = e.Name or newText()
			e.Name.Text = m.Name
			e.Name.Position = UDim2.fromOffset((x1 + x2) / 2, y1 - 2)
		else espDestroyPart(e, "Name") end

		-- Distance
		if F["Esp Distance"] and visible then
			e.Dist = e.Dist or newText()
			e.Dist.AnchorPoint = Vector2.new(0.5, 0)
			e.Dist.Text = string.format("%.0f studs (%.0f m)", t.Dist, t.Dist * 0.28)
			e.Dist.Position = UDim2.fromOffset((x1 + x2) / 2, y2 + 2)
		else espDestroyPart(e, "Dist") end

		-- Hologram: Highlight xuyên tường
		if F["Esp Hologram"] then
			if not e.Hl then
				local h = Instance.new("Highlight")
				h.DepthMode, h.FillTransparency = Enum.HighlightDepthMode.AlwaysOnTop, 0.6
				h.FillColor, h.OutlineColor = Color3.fromRGB(0, 200, 255), Color3.new(1, 1, 1)
				h.Adornee, h.Parent = m, m
				e.Hl = h
			end
		else espDestroyPart(e, "Hl") end
	end
	-- mục tiêu chết / ra khỏi 150 / bị hủy -> dọn chỉ báo
	for m in pairs(Esp.Entries) do
		if not seen[m] then Esp.Cleanup(m) end
	end
end

local function registerEsp(name)
	State.Register(name, function()
		local j = State.Janitor(name)
		if not Esp.Gui or not Esp.Gui.Parent then Esp.Gui = makeGui() end
		if not Esp._conn then
			Esp._conn = RunService.RenderStepped:Connect(function()
				local ok, err = pcall(espUpdate)
				if not ok then warn("[Esp] " .. tostring(err)) end
			end)
		end
		j:Add(function()
			task.defer(function()
				local F = State.Flags
				if not (F["Esp Line"] or F["Esp Box"] or F["Esp Name"] or F["Esp Distance"] or F["Esp Hologram"]) then
					if Esp._conn then Esp._conn:Disconnect(); Esp._conn = nil end
					for m in pairs(Esp.Entries) do Esp.Cleanup(m) end
				end
			end)
		end)
	end, function() end)
end
for _, n in ipairs({ "Esp Line", "Esp Box", "Esp Name", "Esp Distance", "Esp Hologram" }) do registerEsp(n) end

---------------------------------------------------------------------
-- 5) MovementAndWorld
---------------------------------------------------------------------
local Input = { up = false, down = false } -- nút ▲▼ trên màn hình / phím

local function groundY(x, z, refY, ignore)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { ignore }
	local r = Workspace:Raycast(Vector3.new(x, refY + 3, z), Vector3.new(0, -500, 0), rp)
	return r and r.Position.Y or refY
end

-- No Clip: tắt va chạm, khôi phục chính xác trạng thái ban đầu
State.Register("No Clip", function()
	local j = State.Janitor("No Clip")
	local snap = {}
	State.Snap["No Clip"] = snap
	j:Add(RunService.Stepped:Connect(function()
		local ch = LP.Character
		if not ch then return end
		for _, p in ipairs(ch:GetDescendants()) do
			if p:IsA("BasePart") then
				if snap[p] == nil then snap[p] = p.CanCollide end
				p.CanCollide = false
			end
		end
	end))
	j:Add(function()
		for p, v in pairs(snap) do if p.Parent then p.CanCollide = v end end
		table.clear(snap)
	end)
end, function() end)

-- Lõi bay dùng chung cho Fly Air / Fly Dron / Fly Down
local flyModes = { "Fly Air", "Fly Dron", "Fly Down" }
local function registerFly(name, mode)
	State.Register(name, function()
		for _, other in ipairs(flyModes) do if other ~= name then State.Set(other, false) end end
		local j = State.Janitor(name)
		local ch, hum, root = getChar()
		assert(ch, "chưa có nhân vật")
		local snap = { PlatformStand = hum.PlatformStand, AutoRotate = hum.AutoRotate }
		State.Snap[name] = snap
		local gY = groundY(root.Position.X, root.Position.Z, root.Position.Y, ch)
		local turnedNoclip = false
		if mode == "Down" and not State.Flags["No Clip"] then
			State.Set("No Clip", true); turnedNoclip = true
		end
		hum.PlatformStand, hum.AutoRotate = true, false
		local bv = j:Add(Instance.new("BodyVelocity"))
		bv.MaxForce, bv.Velocity, bv.Parent = Vector3.one * 1e7, Vector3.zero, root
		local bg = j:Add(Instance.new("BodyGyro"))
		bg.MaxTorque, bg.P, bg.D, bg.Parent = Vector3.one * 1e7, 2e4, 1e3, root
		local holdY = root.Position.Y -- chống tự lên/xuống khi không bấm
		j:Add(RunService.Heartbeat:Connect(function(dt)
			local c, h, r = getChar()
			if not c then return end
			local cam = Workspace.CurrentCamera
			local look = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
			if look.Magnitude < 0.01 then look = Vector3.new(0, 0, -1) end
			local base = CFrame.lookAt(r.Position, r.Position + look)
			local move = h.MoveDirection * State.Config.FlySpeed
			local v = (Input.up and 1 or 0) - (Input.down and 1 or 0)
			local vy = 0
			if mode == "Air" then
				vy = v * State.Config.FlySpeed
				bg.CFrame = base
			elseif mode == "Dron" then
				if v ~= 0 then State.Config.DroneHeight = clamp(State.Config.DroneHeight + v * dt * 6, 1, 200) end
				gY = groundY(r.Position.X, r.Position.Z, r.Position.Y, c)
				vy = clamp((gY + State.Config.DroneHeight - r.Position.Y) * 6, -40, 40)
				bg.CFrame = base * CFrame.Angles(-math.pi / 2, 0, 0) -- úp mặt xuống
			else -- Down
				if v ~= 0 then State.Config.DownDepth = clamp(State.Config.DownDepth - v * dt * 6, 1, 300) end
				gY = groundY(r.Position.X, r.Position.Z, gY + 1, c)
				vy = clamp((gY - State.Config.DownDepth - r.Position.Y) * 6, -40, 40)
				bg.CFrame = base * CFrame.Angles(math.pi / 2, 0, 0) -- nằm ngửa
			end
			bv.Velocity = Vector3.new(move.X, vy, move.Z)
		end))
		j:Add(function()
			local _, h2 = getChar()
			if h2 then h2.PlatformStand, h2.AutoRotate = snap.PlatformStand, snap.AutoRotate end
			local c2, _, r2 = getChar()
			if r2 then -- đứng thẳng lại, ra khỏi lòng đất nếu cần
				local p = r2.Position
				if mode == "Down" then p = Vector3.new(p.X, gY + 4, p.Z) end
				r2.CFrame = CFrame.new(p) * CFrame.Angles(0, select(2, r2.CFrame:ToEulerAnglesYXZ()), 0)
				zeroVel(r2)
			end
			if turnedNoclip then State.Set("No Clip", false) end
		end)
	end, function() end)
end
registerFly("Fly Air", "Air"); registerFly("Fly Dron", "Dron"); registerFly("Fly Down", "Down")

-- Speed: WalkSpeed thời gian thực, khôi phục khi tắt
State.Register("Speed", function()
	local j = State.Janitor("Speed")
	local _, hum = getChar()
	local orig = hum and hum.WalkSpeed or 16
	State.Snap["Speed"] = { WalkSpeed = orig }
	j:Add(RunService.Heartbeat:Connect(function()
		local _, h = getChar()
		if h then h.WalkSpeed = State.Config.WalkSpeed end
	end))
	j:Add(function() local _, h = getChar(); if h then h.WalkSpeed = orig end end)
end, function() end)

-- Jumping Air: nhảy trên không, không đổi PlatformStand nên vẫn di chuyển bình thường
State.Register("Jumping Air", function()
	local j = State.Janitor("Jumping Air")
	j:Add(UIS.JumpRequest:Connect(function()
		local _, h = getChar()
		if h and h:GetState() ~= Enum.HumanoidStateType.Jumping then
			h:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end))
end, function() end)

-- Night Vision: lưu cấu hình ánh sáng gốc và trả lại khi tắt
State.Register("Night Vision", function()
	local j = State.Janitor("Night Vision")
	local snap = {
		Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime, FogEnd = Lighting.FogEnd,
		FogStart = Lighting.FogStart, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
		GlobalShadows = Lighting.GlobalShadows, Atm = {},
	}
	for _, a in ipairs(Lighting:GetChildren()) do
		if a:IsA("Atmosphere") then snap.Atm[a] = { a.Density, a.Haze } end
	end
	State.Snap["Night Vision"] = snap
	j:Add(RunService.RenderStepped:Connect(function()
		Lighting.Brightness, Lighting.ClockTime = 2, 14
		Lighting.FogStart, Lighting.FogEnd = 1e5, 1e6
		Lighting.Ambient, Lighting.OutdoorAmbient = Color3.fromRGB(200, 200, 200), Color3.fromRGB(200, 200, 200)
		Lighting.GlobalShadows = false
		for a in pairs(snap.Atm) do if a.Parent then a.Density, a.Haze = 0, 0 end end
	end))
	j:Add(function()
		for k, v in pairs(snap) do
			if k ~= "Atm" then pcall(function() Lighting[k] = v end) end
		end
		for a, v in pairs(snap.Atm) do if a.Parent then a.Density, a.Haze = v[1], v[2] end end
	end)
end, function() end)

-- Fix Lag: tắt hiệu ứng nặng (lưu trạng thái để bật lại được)
local HEAVY = { ParticleEmitter = 1, Trail = 1, Beam = 1, Fire = 1, Smoke = 1, Sparkles = 1,
	BloomEffect = 1, BlurEffect = 1, SunRaysEffect = 1, DepthOfFieldEffect = 1, ColorCorrectionEffect = 1 }
State.Register("Fix Lag", function()
	local j = State.Janitor("Fix Lag")
	local snap = { Shadows = Lighting.GlobalShadows, Items = {} }
	State.Snap["Fix Lag"] = snap
	Lighting.GlobalShadows = false
	local function handle(d)
		if HEAVY[d.ClassName] and snap.Items[d] == nil then
			snap.Items[d] = d.Enabled
			d.Enabled = false
		elseif d:IsA("BasePart") and d.CastShadow then
			snap.Items[d] = "shadow"; d.CastShadow = false
		end
	end
	task.spawn(function()
		local n = 0
		for _, d in ipairs(Workspace:GetDescendants()) do
			if not State.Flags["Fix Lag"] then return end
			handle(d); n += 1
			if n % 500 == 0 then task.wait() end -- yield tránh treo
		end
		for _, d in ipairs(Lighting:GetChildren()) do handle(d) end
	end)
	j:Add(Workspace.DescendantAdded:Connect(handle))
	j:Add(function()
		Lighting.GlobalShadows = snap.Shadows
		for d, v in pairs(snap.Items) do
			if d.Parent then
				if v == "shadow" then d.CastShadow = true else d.Enabled = v end
			end
		end
		table.clear(snap.Items)
	end)
end, function() end)

-- Nhân vật hồi sinh: tắt các tính năng gắn với nhân vật cũ để tránh trạng thái lỗi
LP.CharacterAdded:Connect(function()
	for _, n in ipairs({ "Fly Air", "Fly Dron", "Fly Down", "Tele Dron", "No Clip", "Speed", "Player Barrier" }) do
		State.Set(n, false)
	end
end)

---------------------------------------------------------------------
-- 6) UIController
---------------------------------------------------------------------
local UI = {}

local function corner(p, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = p end

function UI.Build()
	local old = LP:WaitForChild("PlayerGui"):FindFirstChild("DebugPanel")
	if old then old:Destroy() end
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "DebugPanel", false, 10
	gui.Parent = LP.PlayerGui

	local main = Instance.new("Frame")
	main.Size, main.Position = UDim2.fromOffset(280, 380), UDim2.new(0, 20, 0.5, -190)
	main.BackgroundColor3, main.BorderSizePixel = Color3.fromRGB(25, 25, 32), 0
	main.Parent = gui; corner(main, 8)

	local title = Instance.new("TextLabel")
	title.Size, title.BackgroundColor3 = UDim2.new(1, 0, 0, 30), Color3.fromRGB(40, 40, 55)
	title.Text, title.TextColor3, title.Font, title.TextSize = "  Debug Panel", Color3.new(1, 1, 1), Enum.Font.GothamBold, 14
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = main; corner(title, 8)

	-- Kéo thả menu
	local dragging, dragStart, startPos
	title.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, i.Position, main.Position
		end
	end)
	UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end)

	local body = Instance.new("Frame")
	body.Size, body.Position, body.BackgroundTransparency = UDim2.new(1, 0, 1, -30), UDim2.fromOffset(0, 30), 1
	body.Parent = main

	-- Thu gọn / mở rộng
	local collapse = Instance.new("TextButton")
	collapse.Size, collapse.Position = UDim2.fromOffset(26, 22), UDim2.new(1, -30, 0, 4)
	collapse.Text, collapse.BackgroundColor3, collapse.TextColor3 = "–", Color3.fromRGB(70, 70, 90), Color3.new(1, 1, 1)
	collapse.Parent = title; corner(collapse, 4)
	local collapsed = false
	collapse.MouseButton1Click:Connect(function()
		collapsed = not collapsed
		body.Visible = not collapsed
		main.Size = collapsed and UDim2.fromOffset(280, 30) or UDim2.fromOffset(280, 380)
		collapse.Text = collapsed and "+" or "–"
	end)

	-- Thanh tab
	local tabBar = Instance.new("Frame")
	tabBar.Size, tabBar.BackgroundTransparency = UDim2.new(1, -10, 0, 28), 1
	tabBar.Position = UDim2.fromOffset(5, 4)
	tabBar.Parent = body
	local tl = Instance.new("UIListLayout"); tl.FillDirection, tl.Padding = Enum.FillDirection.Horizontal, UDim.new(0, 4); tl.Parent = tabBar

	local pages, tabBtns = {}, {}
	local function switchTab(n)
		for name, pg in pairs(pages) do pg.Visible = (name == n) end
		for name, b in pairs(tabBtns) do b.BackgroundColor3 = (name == n) and Color3.fromRGB(80, 110, 220) or Color3.fromRGB(50, 50, 65) end
	end
	local function makePage(name)
		local b = Instance.new("TextButton")
		b.Size, b.Text, b.TextColor3 = UDim2.new(1 / 3, -3, 1, 0), name, Color3.new(1, 1, 1)
		b.Font, b.TextSize = Enum.Font.GothamBold, 13
		b.Parent = tabBar; corner(b, 5)
		b.MouseButton1Click:Connect(function() switchTab(name) end)
		tabBtns[name] = b
		local sf = Instance.new("ScrollingFrame")
		sf.Size, sf.Position = UDim2.new(1, -10, 1, -42), UDim2.fromOffset(5, 38)
		sf.BackgroundTransparency, sf.BorderSizePixel = 1, 0
		sf.ScrollBarThickness, sf.CanvasSize, sf.AutomaticCanvasSize = 4, UDim2.new(), Enum.AutomaticSize.Y
		sf.Parent = body
		local l = Instance.new("UIListLayout"); l.Padding, l.SortOrder = UDim.new(0, 4), Enum.SortOrder.LayoutOrder; l.Parent = sf
		pages[name] = sf
		return sf
	end

	local toggleBtns = {}
	-- Hàng chức năng: nút ON/OFF + ▲▼ để kéo lên/xuống thứ tự tự do
	local function addToggle(page, feature)
		local row = Instance.new("Frame")
		row.Size, row.BackgroundTransparency = UDim2.new(1, -6, 0, 28), 1
		row.LayoutOrder = #page:GetChildren()
		row.Parent = page
		local b = Instance.new("TextButton")
		b.Size, b.Font, b.TextSize, b.TextColor3 = UDim2.new(1, -52, 1, 0), Enum.Font.Gotham, 13, Color3.new(1, 1, 1)
		b.Parent = row; corner(b, 5)
		toggleBtns[feature] = b
		local function refresh()
			local on = State.Flags[feature]
			b.Text = feature .. ": " .. (on and "ON" or "OFF")
			b.BackgroundColor3 = on and Color3.fromRGB(40, 150, 80) or Color3.fromRGB(60, 60, 75)
		end
		refresh()
		b.MouseButton1Click:Connect(function() State.Toggle(feature) end)
		local function mv(dir)
			for _, other in ipairs(page:GetChildren()) do
				if other:IsA("Frame") and other.LayoutOrder == row.LayoutOrder + dir then
					other.LayoutOrder, row.LayoutOrder = row.LayoutOrder, row.LayoutOrder + dir
					return
				end
			end
		end
		for i, sym in ipairs({ "▲", "▼" }) do
			local m = Instance.new("TextButton")
			m.Size, m.Position, m.Text = UDim2.fromOffset(22, 28), UDim2.new(1, -48 + (i - 1) * 24, 0, 0), sym
			m.BackgroundColor3, m.TextColor3 = Color3.fromRGB(50, 50, 65), Color3.new(1, 1, 1)
			m.Parent = row; corner(m, 5)
			m.MouseButton1Click:Connect(function() mv(i == 1 and -1 or 1) end)
		end
		table.insert(State.OnChanged, function(n) if n == feature then refresh() end end)
	end

	-- Ô nhập số có kiểm tra hợp lệ
	local function addNumber(page, label, key, lo, hi)
		local row = Instance.new("Frame")
		row.Size, row.BackgroundTransparency, row.LayoutOrder = UDim2.new(1, -6, 0, 26), 1, #page:GetChildren()
		row.Parent = page
		local t = Instance.new("TextLabel")
		t.Size, t.BackgroundTransparency, t.Text = UDim2.new(1, -80, 1, 0), 1, label
		t.TextColor3, t.Font, t.TextSize, t.TextXAlignment = Color3.fromRGB(200, 200, 210), Enum.Font.Gotham, 12, Enum.TextXAlignment.Left
		t.Parent = row
		local box = Instance.new("TextBox")
		box.Size, box.Position, box.Text = UDim2.fromOffset(70, 24), UDim2.new(1, -72, 0, 1), tostring(State.Config[key])
		box.BackgroundColor3, box.TextColor3, box.ClearTextOnFocus = Color3.fromRGB(45, 45, 60), Color3.new(1, 1, 1), false
		box.Parent = row; corner(box, 4)
		box.FocusLost:Connect(function()
			local n = tonumber(box.Text)
			if n then State.Config[key] = clamp(n, lo, hi) end
			box.Text = tostring(State.Config[key])
		end)
	end

	local main_ = makePage("Main")
	for _, f in ipairs({ "Tele Dron", "Hitbox All Mod", "Tele Kill", "Aimbot", "All Mod Im", "Model Độn Thổ",
		"Model head down", "Player Barrier", "Long Legs" }) do addToggle(main_, f) end
	addNumber(main_, "Khoảng cách an toàn Tele Dron", "SafeHeight", 2, 100)
	addNumber(main_, "Cỡ Hitbox", "HitboxSize", 2, 80)
	addNumber(main_, "Độ sâu Độn Thổ", "UndergroundDepth", 2, 300)
	addNumber(main_, "Độ sâu Head Down", "HeadDepth", 0, 50)
	addNumber(main_, "Chân dài thêm", "LongLegs", 1, 300)

	local esp_ = makePage("Esp")
	for _, f in ipairs({ "Esp Line", "Esp Box", "Esp Name", "Esp Distance", "Esp Hologram" }) do addToggle(esp_, f) end

	local other_ = makePage("Khác")
	for _, f in ipairs({ "Fly Down", "Fly Dron", "No Clip", "Fly Air", "Speed", "Jumping Air", "Night Vision", "Fix Lag" }) do
		addToggle(other_, f)
	end
	addNumber(other_, "Fly Speed", "FlySpeed", 1, 500)
	addNumber(other_, "Speed (WalkSpeed)", "WalkSpeed", 1, 500)
	addNumber(other_, "Độ cao Fly Dron", "DroneHeight", 1, 200)
	addNumber(other_, "Độ sâu Fly Down", "DownDepth", 1, 300)

	switchTab("Main")

	-- Cụm nút ▲▼ trên màn hình khi đang bay
	local fly = Instance.new("Frame")
	fly.Size, fly.Position, fly.BackgroundTransparency = UDim2.fromOffset(60, 130), UDim2.new(1, -80, 0.5, -65), 1
	fly.Visible = false; fly.Parent = gui
	local function holdBtn(text, y, flag)
		local b = Instance.new("TextButton")
		b.Size, b.Position, b.Text, b.TextSize = UDim2.fromOffset(56, 56), UDim2.fromOffset(2, y), text, 24
		b.BackgroundColor3, b.TextColor3, b.BackgroundTransparency = Color3.fromRGB(30, 30, 40), Color3.new(1, 1, 1), 0.2
		b.Parent = fly; corner(b, 10)
		b.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then Input[flag] = true end
		end)
		b.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then Input[flag] = false end
		end)
	end
	holdBtn("▲", 0, "up"); holdBtn("▼", 68, "down")
	table.insert(State.OnChanged, function()
		fly.Visible = State.Flags["Fly Air"] or State.Flags["Fly Dron"] or State.Flags["Fly Down"] or false
		if not fly.Visible then Input.up, Input.down = false, false end
	end)
end

UI.Build()
