--[[
  Hp Team Pro V1 - Menu debug/test (LocalScript)
  Đặt vào: StarterPlayer > StarterPlayerScripts
  Module (trong 1 file): Janitor, StateManager, TargetScanner, NoClip, CombatEngine,
                         EspEngine, MovementAndWorld (Features), UIController
  Cắm cơ chế tấn công của game: sửa hàm Combat.AttackHook(target, mode) ở mục COMBAT.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

-- =====================================================================
-- JANITOR: gom connection/instance/hàm để dọn sạch, tránh rò rỉ khi bật/tắt nhiều lần
-- =====================================================================
local Janitor = {}
Janitor.__index = Janitor
function Janitor.new() return setmetatable({ _t = {} }, Janitor) end
function Janitor:Add(x) table.insert(self._t, x) return x end
function Janitor:Clean()
	for _, x in ipairs(self._t) do
		local t = typeof(x)
		if t == "RBXScriptConnection" then x:Disconnect()
		elseif t == "Instance" then pcall(function() x:Destroy() end)
		elseif t == "function" then pcall(x) end
	end
	table.clear(self._t)
end

-- =====================================================================
-- STATE MANAGER: cờ bật/tắt + cấu hình + vòng đời Start/Stop của từng tính năng
-- =====================================================================
local State = {
	Flags = {}, Janitors = {}, Features = {}, _cbs = {},
	Config = {
		ScanRange = 150, SafeHeight = 12, FlySpeed = 60, WalkSpeed = 16,
		FlyDronHeight = 6, HitboxSize = 15, AttackInterval = 0.12, FlyDownDepth = 8,
	},
}
-- Các tính năng điều khiển vị trí nhân vật: chỉ cho phép 1 cái chạy cùng lúc (tránh tranh CFrame)
local EXCLUSIVE = { TeleDron = true, TeleKill = true, FlyDown = true, FlyDron = true, FlyAir = true }

function State.OnChange(fn) table.insert(State._cbs, fn) end

function State.Set(name, on)
	local f = State.Features[name]
	if not f then return end
	on = on and true or false
	if (State.Flags[name] or false) == on then return end
	if on and EXCLUSIVE[name] then
		for other in pairs(EXCLUSIVE) do
			if other ~= name and State.Flags[other] then State.Set(other, false) end
		end
	end
	State.Flags[name] = on
	if on then
		local j = Janitor.new()
		State.Janitors[name] = j
		local ok, err = pcall(f.Start, j)
		if not ok then -- lỗi khi bật: dọn sạch và trả về OFF
			warn("[HpTeamPro] " .. name .. ": " .. tostring(err))
			j:Clean(); State.Janitors[name] = nil; State.Flags[name] = false
			if f.Stop then pcall(f.Stop) end
		end
	else
		local j = State.Janitors[name]
		if j then j:Clean(); State.Janitors[name] = nil end
		if f.Stop then pcall(f.Stop) end -- khôi phục Snapshot
	end
	for _, cb in ipairs(State._cbs) do task.spawn(cb, name) end
end

-- =====================================================================
-- HELPER NHÂN VẬT
-- =====================================================================
local function getChar()
	local c = LP.Character
	if not c then return end
	local h = c:FindFirstChildOfClass("Humanoid")
	local r = c:FindFirstChild("HumanoidRootPart")
	if h and r and h.Health > 0 then return c, h, r end
end
local function planar(h) local d = h.MoveDirection return Vector3.new(d.X, 0, d.Z) end
local function camYaw()
	local l = Workspace.CurrentCamera.CFrame.LookVector
	return math.atan2(-l.X, -l.Z)
end
local function standUp(pos) -- đặt nhân vật đứng thẳng, trả PlatformStand về false
	local _, h, r = getChar()
	if r then
		r.CFrame = CFrame.new(pos) * CFrame.Angles(0, camYaw(), 0)
		r.AssemblyLinearVelocity = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
	end
	if h then h.PlatformStand = false end
end
-- Lực triệt tiêu trọng lực để lơ lửng ổn định (không tự rơi/trôi)
local function makeHold(j, r)
	local a = j:Add(Instance.new("Attachment")); a.Parent = r
	local f = j:Add(Instance.new("VectorForce"))
	f.Attachment0 = a; f.RelativeTo = Enum.ActuatorRelativeTo.World
	f.ApplyAtCenterOfMass = true; f.Force = Vector3.zero; f.Parent = r
	return function() f.Force = Vector3.new(0, Workspace.Gravity * r.AssemblyMass, 0) end
end

-- =====================================================================
-- TARGET SCANNER: quét theo chu kỳ + cache, dùng GetPartBoundsInRadius (không quét toàn workspace)
-- =====================================================================
local Scanner = { _list = {}, _t = 0, Interval = 0.15 }
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude

function Scanner.Valid(m, fromPos)
	if not m or not m.Parent or m == LP.Character then return false end
	if Players:GetPlayerFromCharacter(m) then return false end -- bỏ người chơi khác
	local hum = m:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false end
	local root = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
	if not root then return false end
	if fromPos and (root.Position - fromPos).Magnitude > State.Config.ScanRange then return false end
	return true, hum, root
end

function Scanner.Get()
	local now = os.clock()
	if now - Scanner._t < Scanner.Interval then return Scanner._list end
	Scanner._t = now
	local list = {}
	local c, _, r = getChar()
	if r then
		overlap.FilterDescendantsInstances = { c }
		local seen = {}
		for _, p in ipairs(Workspace:GetPartBoundsInRadius(r.Position, State.Config.ScanRange, overlap)) do
			local m = p:FindFirstAncestorOfClass("Model")
			if m and not seen[m] then
				seen[m] = true
				local ok, hum, root = Scanner.Valid(m, r.Position)
				if ok then
					table.insert(list, { Model = m, Humanoid = hum, Root = root,
						Dist = (root.Position - r.Position).Magnitude })
				end
			end
		end
		table.sort(list, function(a, b) return a.Dist < b.Dist end) -- ưu tiên gần nhất
	end
	Scanner._list = list
	return list
end

-- =====================================================================
-- NOCLIP (đếm tham chiếu, khôi phục CanCollide gốc chính xác)
-- =====================================================================
local NoClip = { refs = {}, conn = nil, orig = nil }
function NoClip.Acquire(k)
	NoClip.refs[k] = true
	if NoClip.conn then return end
	NoClip.orig = setmetatable({}, { __mode = "k" })
	NoClip.conn = RunService.Stepped:Connect(function()
		local c = LP.Character
		if not c then return end
		for _, p in ipairs(c:GetDescendants()) do
			if p:IsA("BasePart") then
				if NoClip.orig[p] == nil then NoClip.orig[p] = p.CanCollide end
				p.CanCollide = false
			end
		end
	end)
end
function NoClip.Release(k)
	NoClip.refs[k] = nil
	if next(NoClip.refs) then return end
	if NoClip.conn then NoClip.conn:Disconnect(); NoClip.conn = nil end
	for p, v in pairs(NoClip.orig or {}) do if p.Parent then p.CanCollide = v end end
	NoClip.orig = nil
end

-- Điều khiển lên/xuống (nút trên màn hình + phím E/Q)
local Move = { Up = false, Down = false }
function Move.Axis() return (Move.Up and 1 or 0) - (Move.Down and 1 or 0) end

-- =====================================================================
-- COMBAT ENGINE
-- =====================================================================
local Combat = { Target = nil, _last = 0 }

-- >>> CẮM CƠ CHẾ TẤN CÔNG CỦA GAME VÀO ĐÂY <<<
-- target = { Model, Humanoid, Root, Dist }; mode = "Dron" | "TeleKill"
-- Mặc định: kích hoạt Tool đang cầm. Ví dụ cắm Remote của game bạn:
--   game.ReplicatedStorage.Remotes.Attack:FireServer(target.Model)
--   hoặc tool.ToolDamageObject:InvokeServer(target.Model, ...) tuỳ game.
function Combat.AttackHook(target, mode)
	local c = LP.Character
	local tool = c and c:FindFirstChildOfClass("Tool")
	if tool then tool:Activate() end
end

function Combat.Attack(t, mode) -- giới hạn tần suất + pcall để hook lỗi không làm sập vòng lặp
	local now = os.clock()
	if now - Combat._last < State.Config.AttackInterval then return end
	Combat._last = now
	local ok, err = pcall(Combat.AttackHook, t, mode)
	if not ok then warn("[AttackHook] " .. tostring(err)) end
end

-- Khóa mục tiêu: giữ đến khi chết/biến mất/ra khỏi 150, rồi tự chuyển mục tiêu gần nhất
function Combat.Pick()
	local _, _, r = getChar()
	if not r then Combat.Target = nil return end
	local t = Combat.Target
	if t and Scanner.Valid(t.Model, r.Position) then return t end
	Combat.Target = Scanner.Get()[1]
	return Combat.Target
end

-- =====================================================================
-- MOVEMENT & WORLD + COMBAT FEATURES
-- =====================================================================
local F = State.Features
local hbOrig = nil -- bảng gốc của Hitbox (EspEngine dùng để bỏ qua part đã phóng to)

F.TeleDron = {
	Start = function(j)
		local _, _, r0 = getChar(); assert(r0, "Chưa có nhân vật")
		local hold = makeHold(j, r0)
		j:Add(RunService.Heartbeat:Connect(function()
			local _, h, r = getChar()
			if not r then return end
			local t = Combat.Pick()
			if not t then h.PlatformStand = false return end
			h.PlatformStand = true
			local tp = t.Root.Position
			-- Tọa độ phía trên mục tiêu để né đòn cận chiến, nhìn thẳng xuống
			r.CFrame = CFrame.lookAt(tp + Vector3.new(0, State.Config.SafeHeight, 0), tp, Vector3.zAxis)
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
			hold()
			Combat.Attack(t, "Dron")
		end))
	end,
	Stop = function() local _, h = getChar(); if h then h.PlatformStand = false end end,
}

F.TeleKill = {
	Start = function(j)
		j:Add(RunService.Heartbeat:Connect(function()
			local _, _, r = getChar()
			if not r then return end
			local t = Combat.Pick() -- mục tiêu chết -> Pick tự chuyển sang mục tiêu kế
			if not t then return end
			local tp = t.Root.Position
			local pos = (t.Root.CFrame * CFrame.new(0, 0, 5)).Position -- phía sau mục tiêu 5 studs
			r.CFrame = CFrame.lookAt(pos, Vector3.new(tp.X, pos.Y, tp.Z))
			r.AssemblyLinearVelocity = Vector3.zero
			Combat.Attack(t, "TeleKill")
		end))
	end,
}

F.Aimbot = {
	Start = function(j)
		-- Bind sau Camera script để ghim góc nhìn không bị ghi đè; Lerp chống giật khi đổi mục tiêu
		RunService:BindToRenderStep("HpAimbot", Enum.RenderPriority.Camera.Value + 1, function()
			local cam = Workspace.CurrentCamera
			local t = Combat.Pick()
			if not (cam and t) then return end
			local aim = (t.Model:FindFirstChild("Head") or t.Root).Position
			cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(cam.CFrame.Position, aim), 0.25)
		end)
		j:Add(function() RunService:UnbindFromRenderStep("HpAimbot") end)
	end,
}

local function restoreHb(p, o)
	if p and p.Parent then
		p.Size = o[1]; p.CanCollide = o[2]; p.Transparency = o[3]; p.Massless = o[4]
	end
end
F.HitboxAll = {
	Start = function(j)
		hbOrig = setmetatable({}, { __mode = "k" })
		local acc = 0
		local function apply(p, size, inSet)
			inSet[p] = true
			if not hbOrig[p] then hbOrig[p] = { p.Size, p.CanCollide, p.Transparency, p.Massless } end
			p.Size = Vector3.new(size, size, size)
			p.CanCollide = false; p.Transparency = 0.85; p.Massless = true
		end
		j:Add(RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.2 then return end
			acc = 0
			local size, inSet = State.Config.HitboxSize, {}
			-- Phóng to root của mọi mục tiêu hợp lệ: phủ cả dưới đất / xuyên tường (sphere cube bao quanh)
			for _, t in ipairs(Scanner.Get()) do apply(t.Root, size, inSet) end
			-- Phóng to Handle vũ khí đang cầm
			local c = LP.Character
			local tool = c and c:FindFirstChildOfClass("Tool")
			local handle = tool and tool:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then apply(handle, size, inSet) end
			-- Khôi phục part không còn trong diện (chết/ra tầm/cất vũ khí)
			for p, o in pairs(hbOrig) do
				if not inSet[p] then restoreHb(p, o); hbOrig[p] = nil end
			end
		end))
	end,
	Stop = function()
		if hbOrig then for p, o in pairs(hbOrig) do restoreHb(p, o) end end
		hbOrig = nil
	end,
}

F.NoClip = {
	Start = function(j) NoClip.Acquire("User"); j:Add(function() NoClip.Release("User") end) end,
}

local FD = { origY = 0 }
F.FlyDown = {
	Start = function(j)
		local _, _, r = getChar(); assert(r, "Chưa có nhân vật")
		FD.origY = r.Position.Y
		local x, z, y = r.Position.X, r.Position.Z, r.Position.Y - State.Config.FlyDownDepth
		NoClip.Acquire("FlyDown"); j:Add(function() NoClip.Release("FlyDown") end)
		local hold = makeHold(j, r)
		j:Add(RunService.Heartbeat:Connect(function(dt)
			local _, h, root = getChar()
			if not root then return end
			h.PlatformStand = true
			local sp, d = State.Config.FlySpeed, planar(h)
			x += d.X * sp * dt; z += d.Z * sp * dt
			y += Move.Axis() * sp * 0.7 * dt -- chỉ đổi độ sâu khi bấm, không tự trôi
			-- Nằm ngửa mặt lên; camera không bị đụng tới (giữ nguyên góc gốc)
			root.CFrame = CFrame.new(x, y, z) * CFrame.Angles(0, camYaw(), 0) * CFrame.Angles(math.rad(90), 0, 0)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			hold()
		end))
	end,
	Stop = function()
		local _, _, r = getChar()
		if r then standUp(Vector3.new(r.Position.X, FD.origY + 3, r.Position.Z)) end
	end,
}

F.FlyDron = {
	Start = function(j)
		local c0, _, r0 = getChar(); assert(r0, "Chưa có nhân vật")
		local y, lastGround = r0.Position.Y, r0.Position.Y - 3
		local hold = makeHold(j, r0)
		local rp = RaycastParams.new(); rp.FilterType = Enum.RaycastFilterType.Exclude
		j:Add(RunService.Heartbeat:Connect(function(dt)
			local c, h, r = getChar()
			if not r then return end
			h.PlatformStand = true
			local cfg = State.Config
			-- Nút tăng/giảm chỉnh độ cao từ từ
			cfg.FlyDronHeight = math.clamp(cfg.FlyDronHeight + Move.Axis() * 4 * dt, 1, 100)
			rp.FilterDescendantsInstances = { c }
			local hit = Workspace:Raycast(r.Position, Vector3.new(0, -500, 0), rp)
			if hit then lastGround = hit.Position.Y end
			y += ((lastGround + cfg.FlyDronHeight) - y) * math.min(1, dt * 3) -- bay lên/xuống mượt
			local d, p = planar(h), r.Position
			local nx, nz = p.X + d.X * cfg.FlySpeed * dt, p.Z + d.Z * cfg.FlySpeed * dt
			-- Úp mặt xuống, chỉ di chuyển ngang
			r.CFrame = CFrame.new(nx, y, nz) * CFrame.Angles(0, camYaw(), 0) * CFrame.Angles(math.rad(-90), 0, 0)
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
			hold()
		end))
	end,
	Stop = function()
		local _, _, r = getChar()
		if r then standUp(r.Position) end
	end,
}

F.FlyAir = {
	Start = function(j)
		local _, _, r0 = getChar(); assert(r0, "Chưa có nhân vật")
		local hold = makeHold(j, r0)
		j:Add(RunService.Heartbeat:Connect(function()
			local _, h, r = getChar()
			if not r then return end
			h.PlatformStand = true
			local sp = State.Config.FlySpeed
			-- Không bấm = vận tốc 0 + triệt trọng lực => đứng yên đúng độ cao, không tự rơi
			r.AssemblyLinearVelocity = planar(h) * sp + Vector3.new(0, Move.Axis() * sp * 0.7, 0)
			r.AssemblyAngularVelocity = Vector3.zero
			r.CFrame = CFrame.new(r.Position) * CFrame.Angles(0, camYaw(), 0)
			hold()
		end))
	end,
	Stop = function()
		local _, h, r = getChar()
		if h then h.PlatformStand = false end
		if r then r.AssemblyLinearVelocity = Vector3.zero end
	end,
}

local speedOrig = nil
F.Speed = {
	Start = function(j)
		local _, h = getChar(); assert(h, "Chưa có nhân vật")
		speedOrig = h.WalkSpeed
		j:Add(RunService.Heartbeat:Connect(function()
			local _, hum = getChar()
			if hum then hum.WalkSpeed = State.Config.WalkSpeed end -- cập nhật thời gian thực
		end))
	end,
	Stop = function()
		local _, h = getChar()
		if h and speedOrig then h.WalkSpeed = speedOrig end
		speedOrig = nil
	end,
}

F.JumpAir = {
	Start = function(j)
		j:Add(UIS.JumpRequest:Connect(function()
			local _, h = getChar()
			if not h then return end
			-- Gỡ PlatformStand nếu không có chế độ bay nào đang giữ (tránh kẹt không di chuyển)
			if h.PlatformStand and not (State.Flags.FlyAir or State.Flags.FlyDown
				or State.Flags.FlyDron or State.Flags.TeleDron) then h.PlatformStand = false end
			h:ChangeState(Enum.HumanoidStateType.Jumping)
		end))
	end,
}

local NV = nil
local NV_PROPS = { "Brightness", "ClockTime", "FogStart", "FogEnd", "GlobalShadows", "Ambient",
	"OutdoorAmbient", "ExposureCompensation" }
local function nvApply()
	Lighting.Brightness = 2; Lighting.ClockTime = 14
	Lighting.FogStart = 1e8; Lighting.FogEnd = 1e9
	Lighting.GlobalShadows = false
	Lighting.Ambient = Color3.new(1, 1, 1); Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
	Lighting.ExposureCompensation = 0
	for _, a in ipairs(Lighting:GetChildren()) do
		if a:IsA("Atmosphere") then
			if NV and not NV.atm[a] then NV.atm[a] = { a.Density, a.Haze } end
			a.Density = 0; a.Haze = 0
		end
	end
end
F.NightVision = {
	Start = function(j)
		NV = { l = {}, atm = {} }
		for _, k in ipairs(NV_PROPS) do NV.l[k] = Lighting[k] end -- Snapshot gốc
		nvApply()
		local acc = 0
		j:Add(RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc > 0.5 then acc = 0; nvApply() end -- chống game ghi đè
		end))
	end,
	Stop = function()
		if not NV then return end
		for k, v in pairs(NV.l) do pcall(function() Lighting[k] = v end) end
		for a, v in pairs(NV.atm) do if a.Parent then a.Density = v[1]; a.Haze = v[2] end end
		NV = nil
	end,
}

local FL = nil
local function lagOne(i)
	if i:IsA("ParticleEmitter") or i:IsA("Trail") or i:IsA("Beam") or i:IsA("Smoke")
		or i:IsA("Fire") or i:IsA("Sparkles") or i:IsA("PostEffect") then
		if i.Enabled then FL.inst[i] = "Enabled"; i.Enabled = false end
	elseif i:IsA("BasePart") and i.CastShadow then
		FL.inst[i] = "CastShadow"; i.CastShadow = false
	end
end
F.FixLag = {
	Start = function(j)
		FL = { inst = setmetatable({}, { __mode = "k" }), shadows = Lighting.GlobalShadows }
		Lighting.GlobalShadows = false
		local alive = true
		j:Add(function() alive = false end)
		task.spawn(function() -- chia lô, yield để không đứng hình
			local n = 0
			for _, root in ipairs({ Workspace, Lighting }) do
				for _, i in ipairs(root:GetDescendants()) do
					if not alive then return end
					pcall(lagOne, i)
					n += 1
					if n % 400 == 0 then task.wait() end
				end
			end
		end)
		j:Add(Workspace.DescendantAdded:Connect(function(i) if alive then pcall(lagOne, i) end end))
	end,
	Stop = function()
		if not FL then return end
		for i, prop in pairs(FL.inst) do if i.Parent then pcall(function() i[prop] = true end) end end
		Lighting.GlobalShadows = FL.shadows
		FL = nil
	end,
}

-- =====================================================================
-- ESP ENGINE (vẽ bằng GUI + Highlight; dọn sạch khi tắt / mục tiêu chết / ra tầm)
-- =====================================================================
local C = {
	bg = Color3.fromHex("0C0E0C"), bg2 = Color3.fromHex("141814"),
	green = Color3.fromHex("00FF66"), off = Color3.fromHex("8A938A"),
}
local Esp = { Gui = nil, Entries = {}, refs = 0, conn = nil, WS = {} }

function Esp.Ensure()
	if Esp.Gui and Esp.Gui.Parent then return end
	local g = Instance.new("ScreenGui")
	g.Name = "HpEsp"; g.ResetOnSpawn = false; g.IgnoreGuiInset = true; g.DisplayOrder = 50
	g.Parent = PlayerGui
	Esp.Gui = g
end

local function comp(e, k, on, make)
	if on then
		if not e[k] then e[k] = make() end
		return e[k]
	end
	if e[k] then e[k]:Destroy(); e[k] = nil end
end
local function clearEntry(e)
	for _, k in ipairs({ "line", "box", "label", "hl" }) do
		if e[k] then e[k]:Destroy(); e[k] = nil end
	end
end
function Esp.ClearAll()
	for _, e in pairs(Esp.Entries) do clearEntry(e) end
	table.clear(Esp.Entries)
end

local function mkLine()
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0; f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = C.green; f.Parent = Esp.Gui
	return f
end
local function mkBox()
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1; f.BorderSizePixel = 0; f.AnchorPoint = Vector2.new(0.5, 0.5)
	local s = Instance.new("UIStroke"); s.Color = C.green; s.Thickness = 1.5; s.Parent = f
	f.Parent = Esp.Gui
	return f
end
local function mkLabel()
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1; l.Size = UDim2.fromOffset(160, 30)
	l.AnchorPoint = Vector2.new(0.5, 1); l.TextColor3 = C.green
	l.TextStrokeTransparency = 0; l.Font = Enum.Font.GothamBold; l.TextSize = 12
	l.Parent = Esp.Gui
	return l
end
local function setLine(f, a, b)
	local d = b - a
	f.Size = UDim2.fromOffset(d.Magnitude, 1.5)
	f.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
	f.Rotation = math.deg(math.atan2(d.Y, d.X))
end

local function absV(v) return Vector3.new(math.abs(v.X), math.abs(v.Y), math.abs(v.Z)) end
-- AABB theo hệ tọa độ root, bỏ qua part đã bị Hitbox phóng to (để Box luôn khớp kích thước thật)
local function localBounds(model, root)
	local mn = Vector3.new(math.huge, math.huge, math.huge)
	local mx = -mn
	local inv = root.CFrame:Inverse()
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and not (hbOrig and hbOrig[p]) then
			local cf, s = inv * p.CFrame, p.Size / 2
			local ext = absV(cf.RightVector) * s.X + absV(cf.UpVector) * s.Y + absV(cf.LookVector) * s.Z
			mn = mn:Min(cf.Position - ext); mx = mx:Max(cf.Position + ext)
		end
	end
	if mn.X == math.huge then mn = Vector3.new(-2, -3, -1); mx = Vector3.new(2, 3, 1) end
	return mn, mx
end

function Esp.Update()
	local Fl = State.Flags
	Esp.Ensure()
	local cam = Workspace.CurrentCamera
	local vp = cam.ViewportSize
	local _, _, myRoot = getChar()
	local seen = {}
	if myRoot then
		for _, t in ipairs(Scanner.Get()) do
			local model, root = t.Model, t.Root
			-- Kiểm tra lại mỗi khung hình: mục tiêu chết/ra tầm bị xoá chỉ báo ngay
			if Scanner.Valid(model, myRoot.Position) then
				seen[model] = true
				local e = Esp.Entries[model]
				if not e then e = {}; Esp.Entries[model] = e end
				local sp = cam:WorldToViewportPoint(root.Position)

				local ln = comp(e, "line", Fl.EspLine, mkLine)
				if ln then
					ln.Visible = sp.Z > 0
					if sp.Z > 0 then setLine(ln, Vector2.new(vp.X / 2, 0), Vector2.new(sp.X, sp.Y)) end
				end

				comp(e, "hl", Fl.EspHologram, function()
					local h = Instance.new("Highlight")
					h.Adornee = model; h.FillColor = Color3.fromRGB(255, 60, 60)
					h.FillTransparency = 0.6; h.OutlineColor = C.green
					h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					h.Parent = Esp.Gui
					return h
				end)

				local box = comp(e, "box", Fl.EspBox, mkBox)
				local lbl = comp(e, "label", Fl.EspName or Fl.EspDistance, mkLabel)
				if box or lbl then
					if not e.bounds or os.clock() - e.bt > 0.5 then -- cache bounds 0.5s
						e.bounds = { localBounds(model, root) }; e.bt = os.clock()
					end
					local mn, mx = e.bounds[1], e.bounds[2]
					local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
					local ok = true
					for _, ix in ipairs({ mn.X, mx.X }) do
						for _, iy in ipairs({ mn.Y, mx.Y }) do
							for _, iz in ipairs({ mn.Z, mx.Z }) do
								local v = cam:WorldToViewportPoint(root.CFrame:PointToWorldSpace(Vector3.new(ix, iy, iz)))
								if v.Z <= 0 then ok = false end
								minX = math.min(minX, v.X); maxX = math.max(maxX, v.X)
								minY = math.min(minY, v.Y); maxY = math.max(maxY, v.Y)
							end
						end
					end
					if box then
						box.Visible = ok
						if ok then
							box.Position = UDim2.fromOffset((minX + maxX) / 2, (minY + maxY) / 2)
							box.Size = UDim2.fromOffset(maxX - minX, maxY - minY)
						end
					end
					if lbl then
						lbl.Visible = ok
						if ok then
							local lines = {}
							if Fl.EspName then table.insert(lines, model.Name) end
							if Fl.EspDistance then
								local d = (root.Position - myRoot.Position).Magnitude
								table.insert(lines, string.format("%d studs | %.0f m", d, d * 0.28))
							end
							lbl.Text = table.concat(lines, "\n")
							lbl.Position = UDim2.fromOffset((minX + maxX) / 2, minY - 2)
						end
					end
				end
			end
		end
	end
	for m, e in pairs(Esp.Entries) do -- dọn mục tiêu không còn hợp lệ
		if not seen[m] then clearEntry(e); Esp.Entries[m] = nil end
	end
end

function Esp.Retain()
	Esp.refs += 1
	if Esp.conn then return end
	Esp.conn = RunService.RenderStepped:Connect(function()
		local ok, err = pcall(Esp.Update)
		if not ok then warn("[Esp] " .. tostring(err)) end
	end)
end
function Esp.Release()
	Esp.refs = math.max(0, Esp.refs - 1)
	if Esp.refs == 0 then
		if Esp.conn then Esp.conn:Disconnect(); Esp.conn = nil end
		Esp.ClearAll()
	end
end
for _, n in ipairs({ "EspLine", "EspBox", "EspName", "EspDistance", "EspHologram" }) do
	F[n] = { Start = function() Esp.Retain() end, Stop = function() Esp.Release() end }
end

-- Esp Workspace: quét an toàn workspace.Item, Highlight tối đa 30 vật gần nhất (giới hạn render của Roblox ~31)
local function wsClear() for _, h in pairs(Esp.WS) do h:Destroy() end table.clear(Esp.WS) end
F.EspWorkspace = {
	Start = function(j)
		local acc = 1
		j:Add(RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.5 then return end
			acc = 0
			local _, _, r = getChar()
			local item = Workspace:FindFirstChild("Item") -- kiểm tra tồn tại trước khi truy cập
			local keep, cand = {}, {}
			if r and item then
				for _, o in ipairs(item:GetChildren()) do
					if o:IsA("Model") or o:IsA("BasePart") then
						local hum = o:FindFirstChildOfClass("Humanoid")
						if not (hum and hum.Health <= 0) then
							local d = (o:GetPivot().Position - r.Position).Magnitude
							if d <= State.Config.ScanRange then table.insert(cand, { o, d }) end
						end
					end
				end
				table.sort(cand, function(a, b) return a[2] < b[2] end)
			end
			Esp.Ensure()
			for i = 1, math.min(30, #cand) do
				local o = cand[i][1]
				keep[o] = true
				if not Esp.WS[o] then
					local h = Instance.new("Highlight")
					h.Adornee = o; h.FillColor = Color3.fromRGB(255, 220, 60); h.FillTransparency = 0.5
					h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; h.Parent = Esp.Gui
					Esp.WS[o] = h
				end
			end
			for o, h in pairs(Esp.WS) do
				if not keep[o] then h:Destroy(); Esp.WS[o] = nil end
			end
		end))
	end,
	Stop = wsClear,
}

-- =====================================================================
-- UI CONTROLLER: menu 350x200, kéo thả, thu nhỏ, 3 tab, cuộn danh sách chức năng
-- =====================================================================
local UI = { rows = {}, conns = Janitor.new() }

local TABS = {
	{ id = "Main", items = {
		{ "toggle", "TeleDron", "Tele Dron" }, { "toggle", "HitboxAll", "Hitbox All Mod" },
		{ "toggle", "TeleKill", "Tele Kill" }, { "toggle", "Aimbot", "Aimbot" },
		{ "num", "SafeHeight", "Cao Tele Dron", 3, 60 }, { "num", "HitboxSize", "Cỡ Hitbox", 2, 60 },
		{ "num", "ScanRange", "Phạm vi quét", 20, 500 },
	} },
	{ id = "Esp", items = {
		{ "toggle", "EspLine", "Esp Line" }, { "toggle", "EspBox", "Esp Box" },
		{ "toggle", "EspName", "Esp Name" }, { "toggle", "EspDistance", "Esp Distance" },
		{ "toggle", "EspHologram", "Esp Hologram" }, { "toggle", "EspWorkspace", "Esp Workspace" },
	} },
	{ id = "Khác", items = {
		{ "toggle", "FlyDown", "Fly Down" }, { "toggle", "FlyDron", "Fly Dron" },
		{ "num", "FlyDronHeight", "Độ cao Fly Dron", 1, 100 },
		{ "toggle", "NoClip", "No Clip" }, { "toggle", "FlyAir", "Fly Air" },
		{ "num", "FlySpeed", "Fly Speed", 5, 300 },
		{ "toggle", "Speed", "Speed" }, { "num", "WalkSpeed", "Giá trị Speed", 1, 200 },
		{ "toggle", "JumpAir", "Jumping Air" }, { "toggle", "NightVision", "Night Vision" },
		{ "toggle", "FixLag", "Fix Lag" },
	} },
}

local function stroke(o, th) local s = Instance.new("UIStroke"); s.Color = C.green; s.Thickness = th or 1; s.Parent = o return s end
local function mkBtn(parent, text, size, pos)
	local b = Instance.new("TextButton")
	b.Size = size; b.Position = pos or UDim2.new(); b.BackgroundColor3 = C.bg2
	b.BorderSizePixel = 0; b.Text = text; b.TextColor3 = C.green
	b.Font = Enum.Font.GothamBold; b.TextSize = 12; b.AutoButtonColor = true; b.Parent = parent
	return b
end

function UI.Build()
	local gui = Instance.new("ScreenGui")
	gui.Name = "HpTeamProV1"; gui.ResetOnSpawn = false; gui.DisplayOrder = 100; gui.Parent = PlayerGui
	UI.Gui = gui

	local main = Instance.new("Frame")
	main.Size = UDim2.fromOffset(350, 200); main.Position = UDim2.new(0.5, -175, 0.5, -100)
	main.BackgroundColor3 = C.bg; main.BorderSizePixel = 0; main.ClipsDescendants = true
	main.Active = true; main.Parent = gui
	stroke(main, 1.5)

	local title = Instance.new("Frame")
	title.Size = UDim2.new(1, 0, 0, 24); title.BackgroundColor3 = C.bg2
	title.BorderSizePixel = 0; title.Parent = main
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1, -60, 1, 0); tl.Position = UDim2.fromOffset(8, 0)
	tl.BackgroundTransparency = 1; tl.Text = "Hp Team Pro V1"; tl.TextColor3 = C.green
	tl.Font = Enum.Font.GothamBold; tl.TextSize = 13; tl.TextXAlignment = Enum.TextXAlignment.Left
	tl.Parent = title
	local minB = mkBtn(title, "–", UDim2.fromOffset(24, 24), UDim2.new(1, -52, 0, 0))
	local closeB = mkBtn(title, "X", UDim2.fromOffset(24, 24), UDim2.new(1, -26, 0, 0))

	local tabBar = Instance.new("Frame")
	tabBar.Size = UDim2.new(1, 0, 0, 22); tabBar.Position = UDim2.fromOffset(0, 24)
	tabBar.BackgroundColor3 = C.bg; tabBar.BorderSizePixel = 0; tabBar.Parent = main
	local tl2 = Instance.new("UIListLayout"); tl2.FillDirection = Enum.FillDirection.Horizontal
	tl2.Padding = UDim.new(0, 2); tl2.Parent = tabBar

	local body = Instance.new("ScrollingFrame")
	body.Size = UDim2.new(1, 0, 1, -46); body.Position = UDim2.fromOffset(0, 46)
	body.BackgroundTransparency = 1; body.BorderSizePixel = 0; body.ScrollBarThickness = 3
	body.ScrollBarImageColor3 = C.green; body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new(); body.Parent = main
	local lay = Instance.new("UIListLayout"); lay.Padding = UDim.new(0, 3); lay.Parent = body
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4); pad.PaddingRight = UDim.new(0, 6); pad.PaddingTop = UDim.new(0, 3)
	pad.Parent = body

	local tabBtns = {}
	local function show(idx)
		for _, ch in ipairs(body:GetChildren()) do
			if ch:IsA("GuiObject") then ch:Destroy() end
		end
		table.clear(UI.rows)
		for i, b in ipairs(tabBtns) do b.TextColor3 = (i == idx) and C.green or C.off end
		for order, it in ipairs(TABS[idx].items) do
			local kind, key, text = it[1], it[2], it[3]
			if kind == "toggle" then
				local b = mkBtn(body, "", UDim2.new(1, 0, 0, 26))
				b.LayoutOrder = order; b.TextXAlignment = Enum.TextXAlignment.Left
				local pd = Instance.new("UIPadding"); pd.PaddingLeft = UDim.new(0, 8); pd.Parent = b
				local function refresh()
					local on = State.Flags[key]
					b.Text = text .. "   [" .. (on and "ON" or "OFF") .. "]"
					b.TextColor3 = on and C.green or C.off
					b.BackgroundColor3 = on and Color3.fromHex("1B2A1F") or C.bg2
				end
				b.MouseButton1Click:Connect(function() State.Set(key, not State.Flags[key]) end)
				UI.rows[key] = refresh; refresh()
			else
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, 0, 0, 26); row.BackgroundColor3 = C.bg2
				row.BorderSizePixel = 0; row.LayoutOrder = order; row.Parent = body
				local l = Instance.new("TextLabel")
				l.Size = UDim2.new(1, -90, 1, 0); l.Position = UDim2.fromOffset(8, 0)
				l.BackgroundTransparency = 1; l.Text = text; l.TextColor3 = C.off
				l.Font = Enum.Font.Gotham; l.TextSize = 12; l.TextXAlignment = Enum.TextXAlignment.Left
				l.Parent = row
				local tb = Instance.new("TextBox")
				tb.Size = UDim2.fromOffset(76, 20); tb.Position = UDim2.new(1, -80, 0, 3)
				tb.BackgroundColor3 = C.bg; tb.BorderSizePixel = 0; tb.TextColor3 = C.green
				tb.Font = Enum.Font.GothamBold; tb.TextSize = 12; tb.ClearTextOnFocus = false
				tb.Text = string.format("%.0f", State.Config[key]); tb.Parent = row
				stroke(tb, 1)
				tb.FocusLost:Connect(function()
					local n = tonumber(tb.Text) -- chỉ nhận số hợp lệ, kẹp trong [min,max]
					if n then State.Config[key] = math.clamp(n, it[4], it[5]) end
					tb.Text = string.format("%.0f", State.Config[key])
				end)
				UI.rows[key] = function() if not tb:IsFocused() then tb.Text = string.format("%.0f", State.Config[key]) end end
			end
		end
		body.CanvasPosition = Vector2.zero
	end
	for i, t in ipairs(TABS) do
		local b = mkBtn(tabBar, t.id, UDim2.new(1 / #TABS, -2, 1, 0))
		b.LayoutOrder = i; b.BackgroundColor3 = C.bg
		b.MouseButton1Click:Connect(function() show(i) end)
		tabBtns[i] = b
	end
	show(1)

	-- Thu gọn / mở rộng
	local collapsed = false
	minB.MouseButton1Click:Connect(function()
		collapsed = not collapsed
		tabBar.Visible = not collapsed; body.Visible = not collapsed
		main.Size = collapsed and UDim2.fromOffset(350, 24) or UDim2.fromOffset(350, 200)
		minB.Text = collapsed and "+" or "–"
	end)
	closeB.MouseButton1Click:Connect(function() UI.Shutdown() end)

	-- Kéo thả bằng thanh tiêu đề (chuột + cảm ứng)
	local dragging, dragStart, startPos = false, nil, nil
	title.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true; dragStart = i.Position; startPos = main.Position
			i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UI.conns:Add(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement
			or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))

	-- Cụm nút ▲▼ (hiện khi có chế độ bay)
	local pad2 = Instance.new("Frame")
	pad2.Size = UDim2.fromOffset(56, 116); pad2.Position = UDim2.new(1, -72, 0.5, -58)
	pad2.BackgroundTransparency = 1; pad2.Visible = false; pad2.Parent = gui
	local function holdBtn(text, y, field)
		local b = mkBtn(pad2, text, UDim2.fromOffset(56, 54), UDim2.fromOffset(0, y))
		b.TextSize = 22; stroke(b, 1.5)
		b.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				Move[field] = true
				i.Changed:Connect(function()
					if i.UserInputState == Enum.UserInputState.End then Move[field] = false end
				end)
			end
		end)
	end
	holdBtn("▲", 0, "Up"); holdBtn("▼", 62, "Down")
	UI.Pad = pad2

	State.OnChange(function(name)
		if UI.rows[name] then UI.rows[name]() end
		pad2.Visible = (State.Flags.FlyAir or State.Flags.FlyDown or State.Flags.FlyDron) and true or false
		if not pad2.Visible then Move.Up = false; Move.Down = false end
	end)
	-- Đồng bộ ô số theo thời gian thực (Fly Dron chỉnh độ cao bằng nút)
	local acc = 0
	UI.conns:Add(RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc > 0.25 then acc = 0; if UI.rows.FlyDronHeight then UI.rows.FlyDronHeight() end end
	end))
end

-- Phím tắt E (lên) / Q (xuống) khi đang bay
UI.conns:Add(UIS.InputBegan:Connect(function(i, gp)
	if gp then return end
	if i.KeyCode == Enum.KeyCode.E then Move.Up = true elseif i.KeyCode == Enum.KeyCode.Q then Move.Down = true end
end))
UI.conns:Add(UIS.InputEnded:Connect(function(i)
	if i.KeyCode == Enum.KeyCode.E then Move.Up = false elseif i.KeyCode == Enum.KeyCode.Q then Move.Down = false end
end))

-- Hồi sinh/đổi nhân vật: tắt các chức năng gắn với nhân vật cũ để trạng thái luôn nhất quán
local CHAR_FEATURES = { "TeleDron", "TeleKill", "FlyDown", "FlyDron", "FlyAir", "NoClip", "Speed", "JumpAir" }
UI.conns:Add(LP.CharacterRemoving:Connect(function()
	for _, n in ipairs(CHAR_FEATURES) do State.Set(n, false) end
	Combat.Target = nil
end))

function UI.Shutdown() -- thoát: tắt hết, khôi phục Snapshot, dọn mọi connection/GUI
	for name in pairs(State.Features) do State.Set(name, false) end
	Esp.ClearAll(); wsClear()
	if Esp.Gui then Esp.Gui:Destroy() end
	if UI.Gui then UI.Gui:Destroy() end
	UI.conns:Clean()
end

UI.Build()
