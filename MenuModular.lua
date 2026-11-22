--[[ Menu 3 tab: Main / Esp / Khác — kiến trúc module
     Chạy 1 lần là đủ; chạy lại sẽ tự dọn bản cũ. ]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local LP = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

if _G.__MenuCleanup then pcall(_G.__MenuCleanup) end

---------------------------------------------------------------- Maid (dọn kết nối/đối tượng)
local function newMaid()
	local m = { items = {} }
	function m:Give(x) table.insert(self.items, x) return x end
	function m:Clean()
		for _, i in ipairs(self.items) do
			local t = typeof(i)
			if t == "RBXScriptConnection" then i:Disconnect()
			elseif t == "Instance" then pcall(i.Destroy, i)
			elseif t == "function" then pcall(i) end
		end
		table.clear(self.items)
	end
	return m
end
local Root = newMaid() -- dọn toàn bộ khi chạy lại

local function hum() local c = LP.Character return c and c:FindFirstChildOfClass("Humanoid") end
local function hrp() local c = LP.Character return c and c:FindFirstChild("HumanoidRootPart") end
local function every(sec, fn)
	local acc = 0
	return RunService.Heartbeat:Connect(function(dt) acc += dt if acc >= sec then acc = 0 fn() end end)
end

---------------------------------------------------------------- StateManager
local State = {
	Flags = {}, Listeners = {}, OnChanged = {},
	Config = { ScanRange = 150, SafeHeight = 12, DroneHeight = 6, FlySpeed = 50,
		WalkSpeed = 32, HitboxSize = 15, WeaponReach = 15, AimSmooth = 0.35 },
}
function State:Get(k) return self.Flags[k] == true end
function State:Set(k, v)
	v = v == true
	if (self.Flags[k] == true) == v then return end
	self.Flags[k] = v
	local f = self.Listeners[k]
	if f then local ok, e = pcall(f, v) if not ok then warn("[Menu]", k, e) end end
	for _, cb in ipairs(self.OnChanged) do pcall(cb, k, v) end
end
function State:Bind(k, f) self.Listeners[k] = f end

-- Feature: bật -> chạy fn(maid); tắt -> maid:Clean() (khôi phục snapshot nằm trong maid)
local function Feature(key, fn)
	local maid
	State:Bind(key, function(v)
		if maid then maid:Clean() maid = nil end
		if v then maid = newMaid() fn(maid) end
	end)
	Root:Give(function() if maid then maid:Clean() end end)
end

---------------------------------------------------------------- TargetScanner
local Scanner = { Humans = {}, Cache = {}, _t = 0 }
local function track(d) if d:IsA("Humanoid") then Scanner.Humans[d] = true end end
task.spawn(function()
	for i, d in ipairs(Workspace:GetDescendants()) do
		track(d)
		if i % 1500 == 0 then task.wait() end
	end
end)
Root:Give(Workspace.DescendantAdded:Connect(track))
Root:Give(Workspace.DescendantRemoving:Connect(function(d) Scanner.Humans[d] = nil end))

function Scanner.Valid(h)
	local m = h.Parent
	if not m or not m:IsA("Model") or h.Health <= 0 then return end
	if m == LP.Character or Players:GetPlayerFromCharacter(m) then return end
	local r = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
	if not r or not r:IsA("BasePart") then return end
	return m, r
end
function Scanner:Refresh()
	local mine, list = hrp(), {}
	if mine then
		for h in pairs(self.Humans) do
			local m, r = self.Valid(h)
			if m then
				local d = (r.Position - mine.Position).Magnitude
				if d <= State.Config.ScanRange then list[#list + 1] = { Model = m, Root = r, Hum = h, Dist = d } end
			end
		end
		table.sort(list, function(a, b) return a.Dist < b.Dist end) -- gần nhất trước
	end
	self.Cache = list
end
function Scanner:Get() -- cache 0.1s để nhẹ CPU
	if os.clock() - self._t > 0.1 then self._t = os.clock() self:Refresh() end
	return self.Cache
end

---------------------------------------------------------------- CombatEngine
local Combat = { Target = nil, _atk = 0, _switch = 0 }

-- ★ CẮM CƠ CHẾ TẤN CÔNG CỦA GAME VÀO ĐÂY ★
-- target = {Model, Root, Hum}; mode = "TeleDron" | "TeleKill".
-- Ví dụ: fire RemoteEvent đánh, gọi skill, hoặc VirtualUser click. Mặc định: kích hoạt Tool đang cầm.
function Combat.AttackHook(target, mode)
	local c = LP.Character
	local tool = c and c:FindFirstChildOfClass("Tool")
	if tool then pcall(function() tool:Activate() end) end
end

function Combat:Attack(t, mode)
	if os.clock() - self._atk < 0.12 then return end
	self._atk = os.clock()
	local ok, e = pcall(self.AttackHook, t, mode)
	if not ok then warn("[AttackHook]", e) end
end
-- Khóa mục tiêu: giữ đến khi chết/biến mất/ra khỏi tầm, rồi tự chuyển sang mục tiêu gần nhất
function Combat:Pick()
	local mine, t = hrp(), self.Target
	if not mine then return end
	if t and t.Hum.Parent and t.Hum.Health > 0 and t.Root.Parent
		and (t.Root.Position - mine.Position).Magnitude <= State.Config.ScanRange then
		return t
	end
	self.Target = Scanner:Get()[1]
	self._switch = os.clock()
	return self.Target
end

local combatMaid
local function combatSync()
	if combatMaid then combatMaid:Clean() combatMaid = nil end
	Combat.Target = nil
	if not (State:Get("TeleDron") or State:Get("TeleKill")) then return end
	combatMaid = newMaid()
	combatMaid:Give(RunService.Heartbeat:Connect(function()
		local root = hrp()
		if not root then return end
		local t = Combat:Pick()
		if not t then return end
		local tp = t.Root.Position
		if State:Get("TeleDron") then
			local pos = tp + Vector3.new(0, State.Config.SafeHeight, 0) -- lơ lửng trên đầu, né cận chiến
			root.CFrame = CFrame.new(pos) * CFrame.Angles(-math.rad(90), 0, 0) -- úp mặt xuống mục tiêu
			root.AssemblyLinearVelocity = Vector3.zero -- triệt tiêu lực rơi/đẩy lùi
			root.AssemblyAngularVelocity = Vector3.zero
			Combat:Attack(t, "TeleDron")
		else
			local pos = (t.Root.CFrame * CFrame.new(0, 0, 4)).Position
			root.CFrame = CFrame.lookAt(pos, Vector3.new(tp.X, pos.Y, tp.Z))
			root.AssemblyLinearVelocity = Vector3.zero
			Combat:Attack(t, "TeleKill")
		end
	end))
end
State:Bind("TeleDron", function(v) if v then State:Set("TeleKill", false) end combatSync() end)
State:Bind("TeleKill", function(v) if v then State:Set("TeleDron", false) end combatSync() end)
Root:Give(function() if combatMaid then combatMaid:Clean() end end)

Feature("Aimbot", function(m)
	m:Give(RunService.RenderStepped:Connect(function()
		local t = Combat:Pick()
		if not t or not t.Root.Parent then return end
		local cam = Workspace.CurrentCamera
		local goal = CFrame.lookAt(cam.CFrame.Position, t.Root.Position)
		-- chống giật khi đổi mục tiêu: 0.2s đầu lerp chậm hơn
		local k = math.clamp((os.clock() - Combat._switch) / 0.2, 0.3, 1)
		cam.CFrame = cam.CFrame:Lerp(goal, State.Config.AimSmooth * k)
	end))
end)

Feature("Hitbox", function(m)
	local snap = setmetatable({}, { __mode = "k" })
	local function restore(p)
		local s = snap[p]
		if s and p.Parent then p.Size, p.Transparency, p.CanCollide, p.Massless = s.S, s.T, s.C, s.M end
		snap[p] = nil
	end
	m:Give(function() for p in pairs(snap) do restore(p) end end)
	m:Give(every(0.25, function()
		local cur = {}
		-- Cỡ hitbox mob = 0 -> không đụng vào mob, chỉ tăng tầm vũ khí
		for _, t in ipairs(State.Config.HitboxSize > 0 and Scanner:Get() or {}) do
			local p = t.Root
			cur[p] = true
			if not snap[p] then snap[p] = { S = p.Size, T = p.Transparency, C = p.CanCollide, M = p.Massless } end
			p.Size = Vector3.one * State.Config.HitboxSize
			p.Transparency, p.CanCollide = 0.7, false
		end
		-- Tăng tầm xa TẤT CẢ vũ khí (Tool trên người + trong Backpack): phóng to Handle
		local reach = State.Config.WeaponReach
		for _, holder in ipairs({ LP.Character, LP:FindFirstChildOfClass("Backpack") }) do
			if holder then
				for _, tool in ipairs(holder:GetChildren()) do
					if tool:IsA("Tool") then
						for _, p in ipairs(tool:GetDescendants()) do
							if p:IsA("BasePart") and p.Name == "Handle" then
								cur[p] = true
								if not snap[p] then snap[p] = { S = p.Size, T = p.Transparency, C = p.CanCollide, M = p.Massless } end
								local s = snap[p].S
								p.Massless = true -- tránh kéo lệch nhân vật
								p.Size = Vector3.new(math.max(s.X, reach), math.max(s.Y, reach), math.max(s.Z, reach))
							end
						end
					end
				end
			end
		end
		for p in pairs(snap) do if not cur[p] then restore(p) end end -- ra khỏi tầm -> trả nguyên
	end))
end)

---------------------------------------------------------------- EspEngine
local Esp = { Objs = {}, maid = nil }
local EspGui = Root:Give(Instance.new("ScreenGui"))
EspGui.Name, EspGui.IgnoreGuiInset, EspGui.ResetOnSpawn, EspGui.DisplayOrder = "E" .. math.random(1e5, 9e5), true, false, 50
local HLFolder = Root:Give(Instance.new("Folder"))
HLFolder.Name = "H" .. math.random(1e5, 9e5)
HLFolder.Parent = Workspace

local function lbl(color)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency, l.TextColor3, l.TextStrokeTransparency = 1, color, 0
	l.Font, l.TextSize, l.Size, l.Visible, l.Parent = Enum.Font.GothamBold, 13, UDim2.fromOffset(200, 14), false, EspGui
	return l
end
function Esp:Make(model)
	local o = {}
	o.Line = Instance.new("Frame") o.Line.BorderSizePixel = 0 o.Line.BackgroundColor3 = Color3.fromRGB(255, 70, 70)
	o.Line.AnchorPoint = Vector2.new(0.5, 0.5) o.Line.Visible = false o.Line.Parent = EspGui
	o.Box = Instance.new("Frame") o.Box.BackgroundTransparency = 1 o.Box.BorderSizePixel = 0 o.Box.Visible = false o.Box.Parent = EspGui
	local s = Instance.new("UIStroke") s.Color = Color3.fromRGB(255, 70, 70) s.Thickness = 1.5 s.Parent = o.Box
	o.Name = lbl(Color3.new(1, 1, 1)) o.Name.AnchorPoint = Vector2.new(0.5, 1) o.Name.Text = model.Name
	o.Dist = lbl(Color3.fromRGB(255, 220, 90)) o.Dist.AnchorPoint = Vector2.new(0.5, 0)
	self.Objs[model] = o
	return o
end
function Esp:Destroy(model)
	local o = self.Objs[model]
	if not o then return end
	for _, k in ipairs({ "Line", "Box", "Name", "Dist", "HL" }) do if o[k] then pcall(o[k].Destroy, o[k]) end end
	self.Objs[model] = nil
end
function Esp:Clear() for m in pairs(self.Objs) do self:Destroy(m) end end

function Esp:Step()
	local seen, mine = {}, hrp()
	local vp = Camera.ViewportSize
	if not mine then self:Clear() return end
	for _, t in ipairs(Scanner:Get()) do
		if t.Hum.Health > 0 and t.Model.Parent then -- mod chết -> không vào seen -> bị xoá
			seen[t.Model] = true
			local o = self.Objs[t.Model] or self:Make(t.Model)
			if State:Get("EspHolo") then
				if not o.HL then
					o.HL = Instance.new("Highlight")
					o.HL.FillTransparency, o.HL.DepthMode = 0.6, Enum.HighlightDepthMode.AlwaysOnTop
					o.HL.Adornee, o.HL.Parent = t.Model, HLFolder
				end
			elseif o.HL then o.HL:Destroy() o.HL = nil end

			local cf, size = t.Model:GetBoundingBox()
			local x0, y0, x1, y1, ok = math.huge, math.huge, -math.huge, -math.huge, true
			for sx = -1, 1, 2 do for sy = -1, 1, 2 do for sz = -1, 1, 2 do
				local v = Camera:WorldToViewportPoint(cf:PointToWorldSpace(Vector3.new(sx, sy, sz) * size / 2))
				if v.Z <= 0 then ok = false else
					x0, y0, x1, y1 = math.min(x0, v.X), math.min(y0, v.Y), math.max(x1, v.X), math.max(y1, v.Y)
				end
			end end end
			local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
			o.Box.Visible = ok and State:Get("EspBox")
			o.Name.Visible = ok and State:Get("EspName")
			o.Dist.Visible = ok and State:Get("EspDist")
			o.Line.Visible = ok and State:Get("EspLine")
			if ok then
				o.Box.Position, o.Box.Size = UDim2.fromOffset(x0, y0), UDim2.fromOffset(x1 - x0, y1 - y0)
				o.Name.Position = UDim2.fromOffset(cx, y0 - 1)
				o.Dist.Position = UDim2.fromOffset(cx, y1 + 1)
				local d = (t.Root.Position - mine.Position).Magnitude
				o.Dist.Text = string.format("%d studs (%.0fm)", d, d * 0.28)
				local dx, dy = cx - vp.X / 2, cy
				o.Line.Position = UDim2.fromOffset(vp.X / 2 + dx / 2, dy / 2)
				o.Line.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), 1.5)
				o.Line.Rotation = math.deg(math.atan2(dy, dx))
			end
		end
	end
	for m in pairs(self.Objs) do if not seen[m] then self:Destroy(m) end end -- ngoài tầm/chết/bị hủy
end
local function espSync()
	local any = State:Get("EspLine") or State:Get("EspBox") or State:Get("EspName") or State:Get("EspDist") or State:Get("EspHolo")
	if any and not Esp.maid then
		Esp.maid = newMaid()
		Esp.maid:Give(RunService.RenderStepped:Connect(function() Esp:Step() end))
	elseif not any and Esp.maid then
		Esp.maid:Clean() Esp.maid = nil
		Esp:Clear()
	end
end
for _, k in ipairs({ "EspLine", "EspBox", "EspName", "EspDist", "EspHolo" }) do State:Bind(k, espSync) end
Root:Give(function() if Esp.maid then Esp.maid:Clean() end Esp:Clear() end)

Feature("EspItem", function(m)
	local hl = {}
	m:Give(function() for _, h in pairs(hl) do pcall(h.Destroy, h) end table.clear(hl) end)
	m:Give(every(0.5, function()
		local folder = Workspace:FindFirstChild("Item") -- kiểm tra tồn tại trước khi truy cập
		local alive = {}
		if folder then
			for _, c in ipairs(folder:GetChildren()) do
				if c:IsA("Model") or c:IsA("BasePart") then
					alive[c] = true
					if not hl[c] then
						local h = Instance.new("Highlight")
						h.FillColor, h.FillTransparency, h.DepthMode = Color3.fromRGB(255, 215, 0), 0.5, Enum.HighlightDepthMode.AlwaysOnTop
						h.Adornee, h.Parent = c, HLFolder
						hl[c] = h
					end
				end
			end
		end
		for c, h in pairs(hl) do if not alive[c] then h:Destroy() hl[c] = nil end end
	end))
end)

---------------------------------------------------------------- MovementAndWorld
local UI = {}
local Move = { Hold = 0, maid = newMaid() }
Root:Give(function() Move.maid:Clean() end)

function Move:Fly(mode) -- "Air" | "Down" (nằm ngửa) | "Dron" (úp mặt, giữ độ cao) | nil = tắt
	self.maid:Clean()
	self.Hold = 0
	if UI.Pad then UI.Pad.Visible = mode ~= nil end
	if not mode then return end
	local char, h, root = LP.Character, hum(), hrp()
	if not (h and root) then return end
	local oldPS = h.PlatformStand
	self.maid:Give(function() local h2 = hum() if h2 then h2.PlatformStand = oldPS end end)
	h.PlatformStand = true
	local bv = self.maid:Give(Instance.new("BodyVelocity"))
	bv.MaxForce, bv.Velocity, bv.Parent = Vector3.one * 9e8, Vector3.zero, root
	local bg = self.maid:Give(Instance.new("BodyGyro"))
	bg.MaxTorque, bg.P, bg.D, bg.Parent = Vector3.one * 9e8, 2e4, 1e3, root
	local rp = RaycastParams.new()
	rp.FilterType, rp.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, { char }
	local C = State.Config
	self.maid:Give(RunService.RenderStepped:Connect(function(dt)
		if not root.Parent or h.Health <= 0 then return end
		local look = Workspace.CurrentCamera.CFrame.LookVector
		local tilt = mode == "Down" and math.rad(90) or (mode == "Dron" and -math.rad(90) or 0)
		bg.CFrame = CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0) * CFrame.Angles(tilt, 0, 0)
		local dir, vy = h.MoveDirection, 0
		if mode == "Dron" then
			C.DroneHeight = math.clamp(C.DroneHeight + self.Hold * dt * 6, 1, 200) -- tăng/giảm từ từ
			local hit = Workspace:Raycast(root.Position, Vector3.new(0, -500, 0), rp)
			if hit then vy = math.clamp((hit.Position.Y + C.DroneHeight - root.Position.Y) * 6, -30, 30) end
		else
			vy = self.Hold * C.FlySpeed * 0.7 -- không nhấn = 0 => đứng yên, không tự rơi/tăng
		end
		bv.Velocity = Vector3.new(dir.X, 0, dir.Z) * C.FlySpeed + Vector3.new(0, vy, 0)
	end))
end

local FLY = { FlyAir = "Air", FlyDown = "Down", FlyDron = "Dron" }
for key, mode in pairs(FLY) do
	State:Bind(key, function(v)
		if v then
			for o in pairs(FLY) do if o ~= key then State:Set(o, false) end end
			if key == "FlyDown" then State:Set("NoClip", true) end -- Fly Down cần xuyên đất
			Move:Fly(mode)
		else
			if key == "FlyDown" then State:Set("NoClip", false) end
			if not (State:Get("FlyAir") or State:Get("FlyDown") or State:Get("FlyDron")) then Move:Fly(nil) end
		end
	end)
end
Root:Give(LP.CharacterAdded:Connect(function() for k in pairs(FLY) do State:Set(k, false) end end))

Feature("NoClip", function(m)
	local snap = {}
	m:Give(function() for p in pairs(snap) do if p.Parent then p.CanCollide = true end end end)
	m:Give(RunService.Stepped:Connect(function()
		local c = LP.Character
		if not c then return end
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") and p.CanCollide then snap[p] = true p.CanCollide = false end
		end
	end))
end)

Feature("Speed", function(m)
	local h = hum()
	local orig = h and h.WalkSpeed
	m:Give(function() local h2 = hum() if h2 and orig then h2.WalkSpeed = orig end end)
	m:Give(RunService.Heartbeat:Connect(function() local h2 = hum() if h2 then h2.WalkSpeed = State.Config.WalkSpeed end end))
end)

Feature("JumpAir", function(m)
	m:Give(UIS.JumpRequest:Connect(function()
		local h = hum()
		if h and h.Health > 0 then h:ChangeState(Enum.HumanoidStateType.Jumping) end
	end))
end)

Feature("NightVision", function(m)
	local L = Lighting
	local snap = { Brightness = L.Brightness, ClockTime = L.ClockTime, FogEnd = L.FogEnd, FogStart = L.FogStart,
		GlobalShadows = L.GlobalShadows, Ambient = L.Ambient, OutdoorAmbient = L.OutdoorAmbient }
	local atm = L:FindFirstChildOfClass("Atmosphere")
	local ad = atm and atm.Density
	m:Give(function()
		for k, v in pairs(snap) do pcall(function() L[k] = v end) end
		if atm and atm.Parent and ad then atm.Density = ad end
	end)
	m:Give(RunService.RenderStepped:Connect(function()
		L.Brightness, L.ClockTime, L.FogStart, L.FogEnd, L.GlobalShadows = 2, 14, 1e6, 1e6, false
		L.Ambient, L.OutdoorAmbient = Color3.new(1, 1, 1), Color3.new(1, 1, 1)
		if atm and atm.Parent then atm.Density = 0 end
	end))
end)

Feature("FixLag", function(m)
	local snap, shadows = {}, Lighting.GlobalShadows
	local function kill(d)
		if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Beam") or d:IsA("Smoke")
			or d:IsA("Fire") or d:IsA("Sparkles") or d:IsA("PostEffect") then
			if snap[d] == nil then snap[d] = d.Enabled end
			d.Enabled = false
		end
	end
	m:Give(function()
		for d, v in pairs(snap) do if d.Parent then d.Enabled = v end end -- tắt Fix Lag -> trả lại hiệu ứng
		Lighting.GlobalShadows = shadows
	end)
	Lighting.GlobalShadows = false
	m:Give(Workspace.DescendantAdded:Connect(kill))
	m:Give(Lighting.DescendantAdded:Connect(kill))
	task.spawn(function()
		for i, d in ipairs(Workspace:GetDescendants()) do
			kill(d)
			if i % 800 == 0 then task.wait() end
		end
		for _, d in ipairs(Lighting:GetDescendants()) do kill(d) end
	end)
end)

---------------------------------------------------------------- UIController
local parentGui = (gethui and gethui()) or LP:WaitForChild("PlayerGui")
local sg = Root:Give(Instance.new("ScreenGui"))
sg.Name, sg.ResetOnSpawn, sg.IgnoreGuiInset, sg.DisplayOrder = "M" .. math.random(1e5, 9e5), false, true, 100
sg.Parent = parentGui
EspGui.Parent = parentGui
local BG, ACC = Color3.fromRGB(24, 24, 30), Color3.fromRGB(60, 120, 255)

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function corner(o) new("UICorner", { CornerRadius = UDim.new(0, 6) }, o) end

local win = new("Frame", { Size = UDim2.fromOffset(300, 390), Position = UDim2.fromOffset(40, 80), BackgroundColor3 = BG, BorderSizePixel = 0 }, sg)
corner(win)
local bar = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = Color3.fromRGB(35, 35, 45), BorderSizePixel = 0 }, win)
corner(bar)
new("TextLabel", { Size = UDim2.new(1, -40, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1, Text = "Menu",
	TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left }, bar)
local collapse = new("TextButton", { Size = UDim2.fromOffset(28, 24), Position = UDim2.new(1, -32, 0, 4), Text = "–",
	BackgroundColor3 = ACC, TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 16 }, bar)
corner(collapse)

local body = new("Frame", { Size = UDim2.new(1, 0, 1, -32), Position = UDim2.fromOffset(0, 32), BackgroundTransparency = 1 }, win)
local tabsBar = new("Frame", { Size = UDim2.new(1, -12, 0, 28), Position = UDim2.fromOffset(6, 4), BackgroundTransparency = 1 }, body)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4) }, tabsBar)

local fullSize = win.Size
collapse.MouseButton1Click:Connect(function()
	body.Visible = not body.Visible
	win.Size = body.Visible and fullSize or UDim2.fromOffset(300, 32)
	collapse.Text = body.Visible and "–" or "+"
end)

-- Kéo thả cửa sổ (chuột + cảm ứng)
local dragging, dStart, sPos
local function isPtr(i) return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch end
Root:Give(bar.InputBegan:Connect(function(i) if isPtr(i) then dragging, dStart, sPos = true, i.Position, win.Position end end))
Root:Give(UIS.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - dStart
		win.Position = UDim2.new(sPos.X.Scale, sPos.X.Offset + d.X, sPos.Y.Scale, sPos.Y.Offset + d.Y)
	end
end))
Root:Give(UIS.InputEnded:Connect(function(i) if isPtr(i) then dragging = false end end))

local pages, tabBtns = {}, {}
local function showTab(name)
	for n, p in pairs(pages) do p.Visible = n == name end
	for n, b in pairs(tabBtns) do b.BackgroundColor3 = n == name and ACC or Color3.fromRGB(45, 45, 56) end
end
local function Tab(name)
	local b = new("TextButton", { Size = UDim2.new(1 / 3, -3, 1, 0), Text = name, BackgroundColor3 = Color3.fromRGB(45, 45, 56),
		TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 13 }, tabsBar)
	corner(b)
	local p = new("ScrollingFrame", { Size = UDim2.new(1, -12, 1, -42), Position = UDim2.fromOffset(6, 38), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 3, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), Visible = false }, body)
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, p)
	pages[name], tabBtns[name] = p, b
	b.MouseButton1Click:Connect(function() showTab(name) end)
	return p
end

local order = 0
local function Row(page)
	order += 1
	local r = new("Frame", { Size = UDim2.new(1, -6, 0, 30), BackgroundColor3 = Color3.fromRGB(36, 36, 46), BorderSizePixel = 0, LayoutOrder = order }, page)
	corner(r)
	local function mv(txt, x, dir) -- ▲▼ đổi thứ tự chức năng
		local b = new("TextButton", { Size = UDim2.fromOffset(18, 14), Position = UDim2.new(1, -20, 0, x), Text = txt, TextSize = 9,
			BackgroundColor3 = Color3.fromRGB(55, 55, 70), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham }, r)
		b.MouseButton1Click:Connect(function()
			local best
			for _, s in ipairs(page:GetChildren()) do
				if s:IsA("Frame") and s ~= r and ((dir < 0 and s.LayoutOrder < r.LayoutOrder and (not best or s.LayoutOrder > best.LayoutOrder))
					or (dir > 0 and s.LayoutOrder > r.LayoutOrder and (not best or s.LayoutOrder < best.LayoutOrder))) then best = s end
			end
			if best then r.LayoutOrder, best.LayoutOrder = best.LayoutOrder, r.LayoutOrder end
		end)
	end
	mv("▲", 1, -1) mv("▼", 15, 1)
	return r
end
local function Toggle(page, text, key)
	local r = Row(page)
	local b = new("TextButton", { Size = UDim2.new(1, -70, 1, 0), BackgroundTransparency = 1, Text = "  " .. text, TextColor3 = Color3.new(1, 1, 1),
		Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left }, r)
	local st = new("TextLabel", { Size = UDim2.fromOffset(40, 20), Position = UDim2.new(1, -64, 0, 5), Text = "OFF",
		BackgroundColor3 = Color3.fromRGB(150, 50, 50), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold, TextSize = 11 }, r)
	corner(st)
	b.MouseButton1Click:Connect(function() State:Set(key, not State:Get(key)) end)
	table.insert(State.OnChanged, function(k, v)
		if k == key then st.Text = v and "ON" or "OFF" st.BackgroundColor3 = v and Color3.fromRGB(50, 150, 70) or Color3.fromRGB(150, 50, 50) end
	end)
end
local function Number(page, text, key, lo, hi)
	local r = Row(page)
	new("TextLabel", { Size = UDim2.new(1, -90, 1, 0), BackgroundTransparency = 1, Text = "  " .. text, TextColor3 = Color3.fromRGB(200, 200, 210),
		Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left }, r)
	local box = new("TextBox", { Size = UDim2.fromOffset(60, 20), Position = UDim2.new(1, -84, 0, 5), Text = tostring(State.Config[key]),
		BackgroundColor3 = Color3.fromRGB(55, 55, 70), TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.Gotham, TextSize = 12, ClearTextOnFocus = false }, r)
	corner(box)
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text) -- chỉ nhận số hợp lệ
		if n then State.Config[key] = math.clamp(n, lo, hi) end
		box.Text = tostring(State.Config[key])
	end)
end

local main, esp, other = Tab("Main"), Tab("Esp"), Tab("Khác")
Toggle(main, "Tele Dron", "TeleDron") Number(main, "Độ cao an toàn", "SafeHeight", 3, 60)
Toggle(main, "Hitbox All Mod", "Hitbox") Number(main, "Cỡ hitbox mob (0=tắt)", "HitboxSize", 0, 80)
Number(main, "Tầm vũ khí", "WeaponReach", 2, 80)
Toggle(main, "Tele Kill", "TeleKill") Toggle(main, "Aimbot", "Aimbot")
Number(main, "Phạm vi quét", "ScanRange", 20, 500)
Toggle(esp, "Esp Line", "EspLine") Toggle(esp, "Esp Box", "EspBox") Toggle(esp, "Esp Name", "EspName")
Toggle(esp, "Esp Distance", "EspDist") Toggle(esp, "Esp Hologram", "EspHolo") Toggle(esp, "Esp Workspace", "EspItem")
Toggle(other, "Fly Down", "FlyDown") Toggle(other, "Fly Dron", "FlyDron") Number(other, "Độ cao Dron", "DroneHeight", 1, 200)
Toggle(other, "No Clip", "NoClip") Toggle(other, "Fly Air", "FlyAir") Number(other, "Fly Speed", "FlySpeed", 5, 300)
Toggle(other, "Speed", "Speed") Number(other, "Walk Speed", "WalkSpeed", 8, 300)
Toggle(other, "Jumping Air", "JumpAir") Toggle(other, "Night Vision", "NightVision") Toggle(other, "Fix Lag", "FixLag")
showTab("Main")

-- Cụm nút tăng/giảm độ cao khi bay
UI.Pad = new("Frame", { Size = UDim2.fromOffset(60, 130), Position = UDim2.new(1, -80, 0.5, -65), BackgroundTransparency = 1, Visible = false }, sg)
local function holdBtn(txt, y, val)
	local b = new("TextButton", { Size = UDim2.fromOffset(60, 60), Position = UDim2.fromOffset(0, y), Text = txt, TextSize = 24,
		BackgroundColor3 = ACC, BackgroundTransparency = 0.25, TextColor3 = Color3.new(1, 1, 1), Font = Enum.Font.GothamBold }, UI.Pad)
	corner(b)
	b.MouseButton1Down:Connect(function() Move.Hold = val end)
	b.MouseButton1Up:Connect(function() if Move.Hold == val then Move.Hold = 0 end end)
	b.MouseLeave:Connect(function() if Move.Hold == val then Move.Hold = 0 end end)
end
holdBtn("▲", 0, 1) holdBtn("▼", 70, -1)

_G.__MenuCleanup = function()
	for k in pairs(State.Flags) do State.Flags[k] = nil end
	Root:Clean()
	_G.__MenuCleanup = nil
end
