--[[
	DEBUG PANEL (LocalScript) - 3 tab: Main / Esp / Khác
	Đặt vào StarterPlayer > StarterPlayerScripts (hoặc dán vào Delta để test).
	Chỉ dùng trong game của bạn.

	CÁCH CẮM CƠ CHẾ TẤN CÔNG CỦA GAME:
	Sửa hàm Combat.AttackHook(target, mode) ở module CombatEngine.
	  target = { model = Model, hum = Humanoid, root = BasePart, dist = number }
	  mode   = "TeleDron" | "TeleKill"
	Ví dụ:
	  - Tool client:   tool:Activate()                    (mặc định bên dưới)
	  - RemoteEvent:   game.ReplicatedStorage.Hit:FireServer(target.model)
	  - Skill/Key:     game.ReplicatedStorage.Skill:FireServer("Slash", target.root.Position)
	Lưu ý: máu mob do SERVER quản lý. Các chế độ chỉnh model mob (Im / Độn Thổ / Head Down /
	Hitbox mob) chỉ đổi phía client, server vẫn dùng vị trí thật nếu mob do server điều khiển.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

-- Dọn bản cũ nếu chạy lại script
for _, n in ipairs({ "DbgPanel", "DbgEsp" }) do
	local o = PlayerGui:FindFirstChild(n)
	if o then o:Destroy() end
end
local oldHL = Workspace:FindFirstChild("DbgEspHL")
if oldHL then oldHL:Destroy() end

-- ===================== TIỆN ÍCH =====================
local function cam() return Workspace.CurrentCamera end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- Trả về: character, HumanoidRootPart, Humanoid (nil nếu chưa có)
local function me()
	local c = LP.Character
	if not c then return end
	return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end

local function new(cls, props, parent)
	local o = Instance.new(cls)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end

-- Maid: gom kết nối/instance/hàm dọn dẹp để không rò rỉ khi bật/tắt nhiều lần
local Maid = {}
Maid.__index = Maid
function Maid.new() return setmetatable({ _t = {} }, Maid) end
function Maid:Add(x)
	table.insert(self._t, x)
	return x
end
function Maid:Clean()
	for _, x in ipairs(self._t) do
		local ty = typeof(x)
		if ty == "RBXScriptConnection" then
			x:Disconnect()
		elseif ty == "Instance" then
			x:Destroy()
		elseif ty == "function" then
			pcall(x)
		end
	end
	table.clear(self._t)
end

-- ===================== MODULE: StateManager =====================
local State = {
	Flags = {},
	Snap = {},
	_l = {},
	Cfg = {
		ScanRange = 150, ModRange = 150,
		SafeHeight = 15, KillOffset = 4,
		DroneHeight = 6, DownDepth = 8,
		FlySpeed = 50, WalkSpeed = 32,
		HitboxSize = 12, BurrowDepth = 12, HeadBury = 4,
		BarrierSize = 14, LegLength = 20, NeckLength = 15,
		AttackInterval = 0.15, AimSmooth = 0.35,
	},
	Range = {
		ScanRange = { 10, 500 }, ModRange = { 10, 500 },
		SafeHeight = { 3, 80 }, KillOffset = { 1, 20 },
		DroneHeight = { 1, 100 }, DownDepth = { 2, 100 },
		FlySpeed = { 5, 300 }, WalkSpeed = { 1, 300 },
		HitboxSize = { 2, 60 }, BurrowDepth = { 2, 100 }, HeadBury = { 0.5, 20 },
		BarrierSize = { 6, 60 }, LegLength = { 2, 100 }, NeckLength = { 2, 100 },
	},
}
-- Các tính năng trong cùng nhóm không chạy cùng lúc (tránh tranh chấp CFrame/Velocity)
local GROUPS = {
	{ "TeleDron", "TeleKill", "FlyAir", "FlyDron", "FlyDown" },
	{ "AllModIm", "ModelDonTho", "ModelHeadDown" },
}

function State:Get(f) return self.Flags[f] == true end

function State:_fire(key, ...)
	for _, fn in ipairs(self._l[key] or {}) do
		local ok, err = pcall(fn, ...)
		if not ok then warn("[Panel]", key, err) end
	end
end

function State:Bind(key, fn)
	self._l[key] = self._l[key] or {}
	table.insert(self._l[key], fn)
end

function State:Set(flag, on)
	on = on == true
	if self:Get(flag) == on then return end
	if on then
		for _, g in ipairs(GROUPS) do
			if table.find(g, flag) then
				for _, o in ipairs(g) do
					if o ~= flag then self:Set(o, false) end
				end
			end
		end
	end
	self.Flags[flag] = on
	self:_fire(flag, on)
	self:_fire("*", flag, on)
end

function State:SetCfg(k, v)
	if type(v) ~= "number" or v ~= v then return false end
	local r = self.Range[k]
	if r then v = clamp(v, r[1], r[2]) end
	self.Cfg[k] = v
	self:_fire("cfg", k, v)
	return true
end

-- Snapshot giá trị gốc (chỉ lưu lần đầu), Take = lấy ra và xoá
function State:Save(k, v)
	if self.Snap[k] == nil then self.Snap[k] = { v = v } end
end
function State:Take(k)
	local s = self.Snap[k]
	self.Snap[k] = nil
	if s then return s.v end
end

-- Mỗi tính năng có 1 Maid riêng: bật tạo mới, tắt dọn sạch
local Features = {}
local function feature(flag, enable)
	State:Bind(flag, function(on)
		local old = Features[flag]
		if old then
			old:Clean()
			Features[flag] = nil
		end
		if on then
			local m = Maid.new()
			Features[flag] = m
			local ok, err = pcall(enable, m)
			if not ok then
				warn("[Panel] Lỗi bật " .. flag .. ": " .. tostring(err))
				m:Clean()
				Features[flag] = nil
				task.defer(State.Set, State, flag, false)
			end
		end
	end)
end

-- ===================== MODULE: TargetScanner =====================
local Scanner = { Cand = {}, List = {}, _acc = 0 }

-- Kiểm tra Humanoid hợp lệ: NPC/Mob còn sống, không phải người chơi, có root
function Scanner:Check(hum)
	if not hum or not hum.Parent then return nil end
	local m = hum.Parent
	if not m:IsA("Model") or hum.Health <= 0 then return nil end
	if m == LP.Character or Players:GetPlayerFromCharacter(m) then return nil end
	local r = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
	if not r or not r:IsA("BasePart") then return nil end
	return m, r
end

-- Làm mới danh sách (throttle 0.1s). List chứa mục tiêu trong max(range)+25, đã sắp xếp theo khoảng cách.
function Scanner:Refresh()
	local _, hrp = me()
	if not hrp then
		self.List = {}
		return
	end
	local range = math.max(State.Cfg.ScanRange, State.Cfg.ModRange) + 25
	local pos = hrp.Position
	local list = {}
	for hum in pairs(self.Cand) do
		local m, r = self:Check(hum)
		if m then
			local d = (r.Position - pos).Magnitude
			if d <= range then
				list[#list + 1] = { model = m, hum = hum, root = r, dist = d }
			end
		elseif not hum.Parent then
			self.Cand[hum] = nil
		end
	end
	-- Ưu tiên gần nhất, phạt nhẹ chênh lệch độ cao (khó tiếp cận hơn)
	for _, e in ipairs(list) do
		e.score = e.dist + math.abs(e.root.Position.Y - pos.Y) * 0.25
	end
	table.sort(list, function(a, b) return a.score < b.score end)
	self.List = list
end

function Scanner:Init(maid)
	local function add(d)
		if d:IsA("Humanoid") then self.Cand[d] = true end
	end
	for _, d in ipairs(Workspace:GetDescendants()) do add(d) end
	maid:Add(Workspace.DescendantAdded:Connect(add))
	maid:Add(Workspace.DescendantRemoving:Connect(function(d) self.Cand[d] = nil end))
	maid:Add(RunService.Heartbeat:Connect(function(dt)
		self._acc += dt
		if self._acc >= 0.1 then
			self._acc = 0
			self:Refresh()
		end
	end))
end

-- ===================== MODULE: CombatEngine =====================
local Combat = { Locked = nil, _last = 0 }

-- >>> ĐIỂM CẮM CƠ CHẾ TẤN CÔNG CỦA GAME <<<
Combat.AttackHook = function(target, mode)
	local c = LP.Character
	local tool = c and c:FindFirstChildOfClass("Tool")
	if tool then tool:Activate() end
end

-- >>> HOOK 'All Mod Im' cho mob bắn xa: chỉnh hướng bắn xuống đất (không trúng người chơi) <<<
-- e = { model, hum, root }. Gọi mỗi 0.2s. Ví dụ: đổi Attribute/Value hướng bắn của mob,
-- hoặc Remote của game. Mặc định để trống vì mỗi game có cơ chế bắn riêng.
Combat.RangedAimDownHook = function(e) end

-- >>> HOOK 'Player Barrier': chặn sát thương từ mod <<<
-- hum = Humanoid của bạn, mobs = danh sách mob gần (trong khoảng rào chắn + 15).
-- Máu thật do server giữ; nếu game có Remote/Attribute khiên thì gọi ở đây.
Combat.BlockDamageHook = function(hum, mobs) end

function Combat:Attack(t, mode)
	local now = os.clock()
	if now - self._last < State.Cfg.AttackInterval then return end
	self._last = now
	local ok, err = pcall(self.AttackHook, t, mode)
	if not ok then warn("[Panel] AttackHook:", err) end
end

-- Khoá mục tiêu tạm thời: giữ mục tiêu cũ tới khi chết/biến mất/ra khỏi tầm, rồi tự chuyển
function Combat:Pick(range)
	local _, hrp = me()
	if not hrp then
		self.Locked = nil
		return nil
	end
	local l = self.Locked
	if l then
		local m, r = Scanner:Check(l.hum)
		if m then
			local d = (r.Position - hrp.Position).Magnitude
			if d <= range + 10 then -- +10 chống nhấp nháy ở mép tầm
				l.root, l.dist = r, d
				return l
			end
		end
		self.Locked = nil
	end
	for _, e in ipairs(Scanner.List) do
		if e.dist <= range and Scanner:Check(e.hum) then
			self.Locked = e
			return e
		end
	end
	return nil
end

-- Treo nhân vật: PlatformStand để Humanoid không tự cân bằng/đẩy lùi
function Combat:Hover(on)
	local _, _, hum = me()
	if on then
		if hum then
			if not State.Snap.ps_hover then State:Save("ps_hover", hum.PlatformStand) end
			hum.PlatformStand = true
		end
	else
		local v = State:Take("ps_hover")
		if hum and v ~= nil then hum.PlatformStand = v end
	end
end

-- Hitbox: lưu kích thước gốc để khôi phục chính xác
local HLFolder -- folder chứa Highlight / hộp vẽ (tạo trong Esp:Init)
local HB = { snap = {} }
local function hbExpand(p, size, kind)
	local s = HB.snap[p]
	if not s then
		s = { Size = p.Size, CanCollide = p.CanCollide, Massless = p.Massless, Transparency = p.Transparency, kind = kind }
		HB.snap[p] = s
	end
	p.Size = size
	p.CanCollide = false -- không bị tường/đất chặn
	if kind == "root" then
		p.Transparency = math.max(s.Transparency, 0.85)
		-- Vẽ hộp bao quanh mod đúng bằng vùng hitbox thực
		if not s.box and HLFolder then
			s.box = new("BoxHandleAdornment", {
				Adornee = p, Size = size, AlwaysOnTop = true, ZIndex = 1,
				Transparency = 0.7, Color3 = Color3.fromRGB(255, 90, 90),
			}, HLFolder)
		end
		if s.box then s.box.Size = size end
	else
		p.Massless = true
	end
end
local function hbRestore(p, s)
	if s.box then
		s.box:Destroy()
		s.box = nil
	end
	if p.Parent then
		p.Size, p.CanCollide, p.Massless, p.Transparency = s.Size, s.CanCollide, s.Massless, s.Transparency
	end
end
function HB:RestoreAll()
	for p, s in pairs(self.snap) do hbRestore(p, s) end
	table.clear(self.snap)
end
function HB:Step()
	local size = Vector3.one * State.Cfg.HitboxSize
	local c = LP.Character
	local bp = LP:FindFirstChildOfClass("Backpack")
	for _, holder in ipairs({ c, bp }) do
		if holder then
			for _, t in ipairs(holder:GetChildren()) do
				if t:IsA("Tool") then
					for _, p in ipairs(t:GetDescendants()) do
						if p:IsA("BasePart") then hbExpand(p, size, "tool") end
					end
				end
			end
		end
	end
	local inR = {}
	for _, e in ipairs(Scanner.List) do
		if e.dist <= State.Cfg.ScanRange then
			inR[e.root] = true
			hbExpand(e.root, size, "root")
		end
	end
	for p, s in pairs(self.snap) do
		if not p.Parent then
			hbRestore(p, s)
			self.snap[p] = nil
		elseif s.kind == "root" and not inR[p] then
			hbRestore(p, s)
			self.snap[p] = nil
		end
	end
end

-- Điều khiển mob: Im / Độn Thổ / Head Down
local Mob = { recs = {} }
local MODE = { AllModIm = "im", ModelDonTho = "burrow", ModelHeadDown = "head" }

-- CFrame cắm ngược đầu xuống đất: chôn "bury" studs phần đầu-vai, thân giữ nguyên vị trí XZ
local function headDownCF(model, bury)
	local pivot = model:GetPivot()
	local bbCF, bbSize = model:GetBoundingBox()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { model, LP.Character }
	local from = bbCF.Position + Vector3.new(0, bbSize.Y / 2 + 2, 0)
	local hit = Workspace:Raycast(from, Vector3.new(0, -1000, 0), rp)
	local groundY = hit and hit.Position.Y or (bbCF.Position.Y - bbSize.Y / 2)
	local _, yaw = pivot:ToEulerAnglesYXZ()
	local boxCF = CFrame.new(bbCF.X, groundY - bury + bbSize.Y / 2, bbCF.Z)
		* CFrame.Angles(0, yaw, 0) * CFrame.Angles(math.pi, 0, 0)
	return boxCF * bbCF:ToObjectSpace(pivot)
end

function Mob:Apply(e, mode, param)
	local m, hum = e.model, e.hum
	local rec = {
		mode = mode, param = param, pivot = m:GetPivot(), hum = hum,
		ws = hum.WalkSpeed, jp = hum.JumpPower, jh = hum.JumpHeight, ar = hum.AutoRotate,
		anch = {}, touch = {},
	}
	for _, p in ipairs(m:GetDescendants()) do
		if p:IsA("BasePart") then
			rec.anch[p], rec.touch[p] = p.Anchored, p.CanTouch
			p.Anchored = true
			p.CanTouch = false -- không gây sát thương qua Touched
		end
	end
	if mode == "burrow" then
		rec.target = rec.pivot - Vector3.new(0, param, 0)
	elseif mode == "head" then
		rec.target = headDownCF(m, param)
	end
	if rec.target then m:PivotTo(rec.target) end
	self.recs[m] = rec
	return rec
end

function Mob:Hold(e, rec)
	local h = e.hum
	h.WalkSpeed, h.JumpPower, h.JumpHeight, h.AutoRotate = 0, 0, 0, false
	if e.root.Anchored == false then e.root.Anchored = true end
	if rec.mode == "im" then pcall(Combat.RangedAimDownHook, e) end
	if rec.target and (e.model:GetPivot().Position - rec.target.Position).Magnitude > 1 then
		e.model:PivotTo(rec.target) -- chống mob bị game kéo bay lên trời
	end
end

function Mob:Restore(model)
	local rec = self.recs[model]
	if not rec then return end
	self.recs[model] = nil
	if rec.target and model.Parent then model:PivotTo(rec.pivot) end
	for p, a in pairs(rec.anch) do
		if p.Parent then
			p.Anchored = a
			p.CanTouch = rec.touch[p]
		end
	end
	local h = rec.hum
	if h and h.Parent then
		h.WalkSpeed, h.JumpPower, h.JumpHeight, h.AutoRotate = rec.ws, rec.jp, rec.jh, rec.ar
	end
end

function Mob:RestoreAll()
	for model in pairs(self.recs) do self:Restore(model) end
end

function Mob:Step(mode)
	local range = State.Cfg.ModRange
	local param = (mode == "burrow" and State.Cfg.BurrowDepth) or (mode == "head" and State.Cfg.HeadBury) or 0
	local seen = {}
	for _, e in ipairs(Scanner.List) do
		local rec = self.recs[e.model]
		if e.dist <= range or (rec and e.dist <= range + 20) then
			seen[e.model] = true
			if rec and (rec.mode ~= mode or rec.param ~= param) then
				self:Restore(e.model)
				rec = nil
			end
			if not rec then rec = self:Apply(e, mode, param) end
			self:Hold(e, rec)
		end
	end
	for model in pairs(self.recs) do
		if not seen[model] then self:Restore(model) end -- mob chết/ra tầm -> trả về như cũ
	end
end

-- Morph: Long Legs / Long Head. Chỉnh Size + C0 của joint, lưu undo để khôi phục chính xác.
-- Không bật cùng các chế độ anchor mob (Im/Độn Thổ/Head Down) vì part bị neo sẽ không theo joint.
local Morph = { recs = { legs = {}, head = {} } }

local function setSnap(undo, inst, prop, val)
	undo[#undo + 1] = { inst, prop, inst[prop] }
	inst[prop] = val
end

function Morph:Apply(kind, e, amount)
	local undo, joints, m = {}, {}, e.model
	local legCount = 0
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("JointInstance") then joints[#joints + 1] = d end
		if d:IsA("BasePart") and d.Name:find("Leg") then legCount += 1 end
	end
	if kind == "legs" then
		-- Kéo dài cẳng chân xuống đất: Size dài thêm, dời khớp xuống amount/2 để đỉnh chân đứng yên;
		-- bàn chân dời theo để dính đáy cẳng chân. Vị trí đứng của mob không đổi.
		for _, p in ipairs(m:GetDescendants()) do
			if p:IsA("BasePart") and p.Name:find("Leg") and not p.Name:find("Upper") then
				local sz = p.Size
				setSnap(undo, p, "Size", Vector3.new(sz.X, sz.Y + amount, sz.Z))
				for _, j in ipairs(joints) do
					local isKnee = j.Part1 == p
					local isAnkle = j.Part0 == p and j.Part1 and j.Part1.Name:find("Foot")
					if isKnee or isAnkle then
						setSnap(undo, j, "C0", CFrame.new(0, -amount / 2, 0) * j.C0)
					end
				end
			end
		end
	else
		-- Kéo cổ: 2 chân (biped) -> kéo lên trời; còn lại -> kéo về phía trước thân
		local head = m:FindFirstChild("Head")
		local biped = legCount >= 2 and legCount <= 6
		if head and head:IsA("BasePart") then
			for _, j in ipairs(joints) do
				if j.Part1 == head and j.Part0 then
					local dir = biped and Vector3.yAxis or e.root.CFrame.LookVector
					local localDir = j.Part0.CFrame:VectorToObjectSpace(dir) * amount
					setSnap(undo, j, "C0", CFrame.new(localDir) * j.C0)
				end
			end
		end
	end
	return undo
end

function Morph:Restore(kind, model)
	local r = self.recs[kind][model]
	if not r then return end
	self.recs[kind][model] = nil
	for i = #r.undo, 1, -1 do
		local u = r.undo[i]
		if u[1].Parent then pcall(function() u[1][u[2]] = u[3] end) end
	end
end

function Morph:RestoreAll(kind)
	for model in pairs(self.recs[kind]) do self:Restore(kind, model) end
end

function Morph:Step(kind)
	local amount = kind == "legs" and State.Cfg.LegLength or State.Cfg.NeckLength
	local recs, range, seen = self.recs[kind], State.Cfg.ModRange, {}
	for _, e in ipairs(Scanner.List) do
		local r = recs[e.model]
		if e.dist <= range or (r and e.dist <= range + 20) then
			seen[e.model] = true
			if r and r.amount ~= amount then
				self:Restore(kind, e.model)
				r = nil
			end
			if not r then
				recs[e.model] = { amount = amount, undo = self:Apply(kind, e, amount) }
			end
		end
	end
	for model in pairs(recs) do
		if not seen[model] then self:Restore(kind, model) end -- mob chết/ra tầm -> trả về như cũ
	end
end

function Combat:InitExtra()
	for flag, kind in pairs({ LongLegs = "legs", LongHead = "head" }) do
		feature(flag, function(m)
			local acc = 1
			m:Add(RunService.Heartbeat:Connect(function(dt)
				acc += dt
				if acc >= 0.3 then
					acc = 0
					Morph:Step(kind)
				end
			end))
			m:Add(function() Morph:RestoreAll(kind) end)
		end)
	end

	-- Player Barrier: 6 tấm rào vô hình (rỗng bên trong) bám theo nhân vật
	feature("PlayerBarrier", function(m)
		local folder = m:Add(new("Folder", { Name = "DbgBarrier" }, Workspace))
		local walls = {}
		for i = 1, 6 do
			walls[i] = new("Part", {
				Anchored = true, CanCollide = true, CanQuery = false, CanTouch = false,
				CastShadow = false, Transparency = 1, Size = Vector3.one,
			}, folder)
		end
		local touchSnap = {}
		local function restoreModel(model)
			local sn = touchSnap[model]
			if not sn then return end
			touchSnap[model] = nil
			for part, v in pairs(sn) do
				if part.Parent then part.CanTouch = v end
			end
		end
		local _, _, h0 = me()
		local last = h0 and h0.Health

		m:Add(RunService.Heartbeat:Connect(function()
			local _, hrp, h = me()
			if not hrp then return end
			local sz, t, pos = State.Cfg.BarrierSize, 1, hrp.Position
			local o = sz / 2
			local defs = {
				{ Vector3.new(o, 0, 0), Vector3.new(t, sz, sz) }, { Vector3.new(-o, 0, 0), Vector3.new(t, sz, sz) },
				{ Vector3.new(0, o, 0), Vector3.new(sz, t, sz) }, { Vector3.new(0, -o, 0), Vector3.new(sz, t, sz) },
				{ Vector3.new(0, 0, o), Vector3.new(sz, sz, t) }, { Vector3.new(0, 0, -o), Vector3.new(sz, sz, t) },
			}
			for i, d in ipairs(defs) do
				walls[i].Size = d[2]
				walls[i].CFrame = CFrame.new(pos + d[1])
			end
			-- Khoá máu phía client (chỉ hiển thị cục bộ, máu thật do server)
			if h then
				if last and h.Health < last then h.Health = last else last = h.Health end
			end
		end))

		local acc = 0
		m:Add(RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc < 0.3 then return end
			acc = 0
			local near, mobs = {}, {}
			for _, e in ipairs(Scanner.List) do
				if e.dist <= State.Cfg.BarrierSize + 15 then
					near[e.model] = true
					mobs[#mobs + 1] = e
					if not touchSnap[e.model] then
						local sn = {}
						for _, part in ipairs(e.model:GetDescendants()) do
							if part:IsA("BasePart") then
								sn[part] = part.CanTouch
								part.CanTouch = false -- tắt sát thương qua Touched phía client
							end
						end
						touchSnap[e.model] = sn
					end
				end
			end
			for model in pairs(touchSnap) do
				if not near[model] then restoreModel(model) end
			end
			local _, _, h = me()
			pcall(Combat.BlockDamageHook, h, mobs)
		end))
		m:Add(function()
			for model in pairs(touchSnap) do restoreModel(model) end
		end)
	end)
end

function Combat:Init()
	-- Tele chung: đặt CFrame theo mục tiêu, triệt tiêu lực rơi/đẩy
	local function tele(flag, place)
		feature(flag, function(m)
			m:Add(RunService.Heartbeat:Connect(function()
				local _, hrp = me()
				if not hrp then return end
				local t = Combat:Pick(State.Cfg.ScanRange)
				if not t then
					Combat:Hover(false)
					return
				end
				Combat:Hover(true)
				hrp.CFrame = place(t)
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
				Combat:Attack(t, flag)
			end))
			m:Add(function()
				Combat:Hover(false)
				Combat.Locked = nil
			end)
		end)
	end

	-- Tele Dron: lơ lửng trên đầu mục tiêu, nhìn thẳng xuống, bám theo khi mục tiêu di chuyển
	tele("TeleDron", function(t)
		local tp = t.root.Position
		return CFrame.lookAt(tp + Vector3.new(0, State.Cfg.SafeHeight, 0), tp, Vector3.zAxis)
	end)

	-- Tele Kill: đứng sau lưng mục tiêu gần nhất, quay mặt vào mục tiêu
	tele("TeleKill", function(t)
		local pos = t.root.CFrame * Vector3.new(0, 0, State.Cfg.KillOffset)
		return CFrame.lookAt(pos, t.root.Position)
	end)

	-- Aimbot: nội suy camera (Lerp) -> mượt, không giật khi đổi mục tiêu
	feature("Aimbot", function(m)
		RunService:BindToRenderStep("DbgAimbot", Enum.RenderPriority.Camera.Value + 1, function()
			local c = cam()
			if not c then return end
			local t = Combat:Pick(State.Cfg.ScanRange)
			if not t then return end
			local head = t.model:FindFirstChild("Head")
			local aim = (head and head:IsA("BasePart") and head.Position) or t.root.Position
			local pos = c.CFrame.Position
			if (aim - pos).Magnitude < 0.5 then return end
			c.CFrame = c.CFrame:Lerp(CFrame.lookAt(pos, aim), State.Cfg.AimSmooth)
		end)
		m:Add(function() RunService:UnbindFromRenderStep("DbgAimbot") end)
	end)

	feature("HitboxAllMod", function(m)
		local acc = 1
		m:Add(RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc >= 0.25 then
				acc = 0
				HB:Step()
			end
		end))
		m:Add(function() HB:RestoreAll() end)
	end)

	for flag, mode in pairs(MODE) do
		feature(flag, function(m)
			local acc = 1
			m:Add(RunService.Heartbeat:Connect(function(dt)
				acc += dt
				if acc >= 0.2 then
					acc = 0
					Mob:Step(mode)
				end
			end))
			m:Add(function() Mob:RestoreAll() end)
		end)
	end
end

-- ===================== MODULE: EspEngine =====================
local Esp = { recs = {}, hlN = 0, hlMax = 30 }

local function mkHL(adornee, parent, color)
	return new("Highlight", {
		Adornee = adornee, FillColor = color, OutlineColor = color,
		FillTransparency = 0.65, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
	}, parent)
end

-- Tính tâm/kích thước khung 3D trong không gian root (bỏ qua HumanoidRootPart vì có thể bị phóng to)
local function measure(model, root)
	local inv = root.CFrame:Inverse()
	local mn, mx
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") and p ~= root and p.Name ~= "HumanoidRootPart" then
			local h = p.Size / 2
			local cf = inv * p.CFrame
			for ix = -1, 1, 2 do
				for iy = -1, 1, 2 do
					for iz = -1, 1, 2 do
						local v = cf * Vector3.new(h.X * ix, h.Y * iy, h.Z * iz)
						if mn then
							mn = Vector3.new(math.min(mn.X, v.X), math.min(mn.Y, v.Y), math.min(mn.Z, v.Z))
							mx = Vector3.new(math.max(mx.X, v.X), math.max(mx.Y, v.Y), math.max(mx.Z, v.Z))
						else
							mn, mx = v, v
						end
					end
				end
			end
		end
	end
	if not mn then
		local s = root.Size
		mn, mx = -s / 2, s / 2
	end
	return (mn + mx) / 2, (mx - mn)
end

local RED = Color3.fromRGB(255, 70, 70)

function Esp:Init(root)
	self.gui = root:Add(new("ScreenGui", { Name = "DbgEsp", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 50 }, PlayerGui))
	HLFolder = root:Add(new("Folder", { Name = "DbgEspHL" }, Workspace))
	self.folder = HLFolder
	root:Add(RunService.RenderStepped:Connect(function(dt) self:Update(dt) end))
end

function Esp:Comp(rec, key, on, make)
	if not on then
		if rec[key] then
			rec[key]:Destroy()
			rec[key] = nil
		end
		return nil
	end
	if not rec[key] then rec[key] = make() end
	return rec[key]
end

function Esp:Kill(rec)
	for _, k in ipairs({ "line", "box", "name", "dist" }) do
		if rec[k] then rec[k]:Destroy() end
	end
	if rec.hl then
		rec.hl:Destroy()
		self.hlN -= 1
	end
end

function Esp:Label()
	return new("TextLabel", {
		BackgroundTransparency = 1, TextColor3 = Color3.new(1, 1, 1), TextStrokeTransparency = 0,
		Font = Enum.Font.GothamBold, TextSize = 13, Size = UDim2.fromOffset(180, 14), Visible = false,
	}, self.gui)
end

function Esp:Draw(rec, e, dist, c)
	local S = State
	local rp = c:WorldToViewportPoint(e.root.Position)
	local onScreen = rp.Z > 0

	-- Cập nhật kích thước khung mỗi 0.5s (không phải mỗi frame)
	if os.clock() - rec.mt > 0.5 then
		rec.center, rec.size = measure(e.model, e.root)
		rec.mt = os.clock()
	end

	local needBox = S:Get("EspBox") or S:Get("EspName") or S:Get("EspDistance")
	local x0, y0, x1, y1
	if needBox and onScreen then
		local mnx, mny, mxx, mxy = math.huge, math.huge, -math.huge, -math.huge
		local ok = true
		local cf = e.root.CFrame
		for ix = -1, 1, 2 do
			for iy = -1, 1, 2 do
				for iz = -1, 1, 2 do
					if ok then
						local sp = c:WorldToViewportPoint(cf * (rec.center + Vector3.new(ix, iy, iz) * rec.size / 2))
						if sp.Z <= 0 then
							ok = false
						else
							mnx, mny = math.min(mnx, sp.X), math.min(mny, sp.Y)
							mxx, mxy = math.max(mxx, sp.X), math.max(mxy, sp.Y)
						end
					end
				end
			end
		end
		if ok then x0, y0, x1, y1 = mnx, mny, mxx, mxy end
	end

	-- Line: từ cạnh trên giữa màn hình
	local line = self:Comp(rec, "line", S:Get("EspLine"), function()
		return new("Frame", { BackgroundColor3 = RED, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5), Visible = false }, self.gui)
	end)
	if line then
		if onScreen then
			local vs = c.ViewportSize
			local ax, ay, bx, by = vs.X / 2, 0, rp.X, rp.Y
			local dx, dy = bx - ax, by - ay
			line.Position = UDim2.fromOffset((ax + bx) / 2, (ay + by) / 2)
			line.Size = UDim2.fromOffset(math.sqrt(dx * dx + dy * dy), 1.5)
			line.Rotation = math.deg(math.atan2(dy, dx))
			line.Visible = true
		else
			line.Visible = false
		end
	end

	-- Box 2D dựng từ 8 góc bounding box 3D
	local box = self:Comp(rec, "box", S:Get("EspBox"), function()
		local f = new("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, Visible = false }, self.gui)
		new("UIStroke", { Color = RED, Thickness = 1.5 }, f)
		return f
	end)
	if box then
		if x0 then
			box.Position = UDim2.fromOffset(x0, y0)
			box.Size = UDim2.fromOffset(x1 - x0, y1 - y0)
			box.Visible = true
		else
			box.Visible = false
		end
	end

	local cx = x0 and (x0 + x1) / 2 or rp.X
	local top = y0 or (rp.Y - 25)
	local bot = y1 or (rp.Y + 25)

	local name = self:Comp(rec, "name", S:Get("EspName"), function() return self:Label() end)
	if name then
		name.Text = e.model.Name
		name.AnchorPoint = Vector2.new(0.5, 1)
		name.Position = UDim2.fromOffset(cx, top - 2)
		name.Visible = onScreen
	end

	local dl = self:Comp(rec, "dist", S:Get("EspDistance"), function() return self:Label() end)
	if dl then
		dl.Text = string.format("%.0f studs (%.0fm)", dist, dist * 0.28)
		dl.TextColor3 = Color3.fromRGB(255, 230, 120)
		dl.AnchorPoint = Vector2.new(0.5, 0)
		dl.Position = UDim2.fromOffset(cx, bot + 2)
		dl.Visible = onScreen
	end

	-- Hologram (Highlight tối đa ~31 cùng lúc trong Roblox -> giới hạn 18)
	if S:Get("EspHologram") then
		if not rec.hl and self.hlN < self.hlMax then
			rec.hl = mkHL(e.model, self.folder, Color3.fromRGB(80, 255, 200))
			self.hlN += 1
		end
	elseif rec.hl then
		rec.hl:Destroy()
		rec.hl = nil
		self.hlN -= 1
	end
end

function Esp:Update(dt)
	local c = cam()
	if not c then return end
	local S = State
	local _, hrp = me()
	local anyDraw = S:Get("EspLine") or S:Get("EspBox") or S:Get("EspName") or S:Get("EspDistance") or S:Get("EspHologram")
	local alive = {}
	if hrp and anyDraw then
		for _, e in ipairs(Scanner.List) do
			local dist = (e.root.Position - hrp.Position).Magnitude
			if dist <= S.Cfg.ScanRange and Scanner:Check(e.hum) then
				alive[e.model] = true
				local rec = self.recs[e.model]
				if not rec then
					rec = { mt = 0, center = Vector3.zero, size = Vector3.new(2, 5, 1) }
					self.recs[e.model] = rec
				end
				self:Draw(rec, e, dist, c)
			end
		end
	end
	-- Dọn chỉ báo của mục tiêu chết/ra tầm/bị huỷ/tắt tính năng
	for model, rec in pairs(self.recs) do
		if not alive[model] then
			self:Kill(rec)
			self.recs[model] = nil
		end
	end
end

function Esp:Cleanup()
	for model, rec in pairs(self.recs) do
		self:Kill(rec)
		self.recs[model] = nil
	end
end

-- ===================== MODULE: MovementAndWorld =====================
local Move = { keyUp = false, keyDown = false, btnUp = false, btnDown = false }
function Move:Vert()
	local v = 0
	if self.keyUp or self.btnUp then v += 1 end
	if self.keyDown or self.btnDown then v -= 1 end
	return v
end

local NoClip = { reasons = {}, snap = {}, conn = nil }
function NoClip:Set(reason, on)
	self.reasons[reason] = on or nil
	if next(self.reasons) then
		if not self.conn then
			self.conn = RunService.Stepped:Connect(function()
				local c = LP.Character
				if not c then return end
				for _, p in ipairs(c:GetDescendants()) do
					if p:IsA("BasePart") then
						if self.snap[p] == nil then self.snap[p] = p.CanCollide end
						if p.CanCollide then p.CanCollide = false end
					end
				end
			end)
		end
	elseif self.conn then
		self.conn:Disconnect()
		self.conn = nil
		for p, v in pairs(self.snap) do
			if p.Parent then p.CanCollide = v end -- khôi phục đúng trạng thái ban đầu
		end
		table.clear(self.snap)
	end
end

local function groundY(hrp)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { LP.Character }
	local r = Workspace:Raycast(hrp.Position, Vector3.new(0, -1000, 0), rp)
	return r and r.Position.Y
end

-- Lõi bay: BodyVelocity luôn về 0 khi không bấm -> không tự rơi/tăng/giảm
-- air = bay tự do | dron = úp mặt, giữ độ cao cách đất | down = ngửa mặt, hạ xuống dưới đất
local function flight(flag, mode)
	feature(flag, function(m)
		local _, hrp, hum = me()
		if not hrp or not hum then error("Chưa có nhân vật") end

		local bv = new("BodyVelocity", { MaxForce = Vector3.one * 1e9, Velocity = Vector3.zero }, hrp)
		local bg = new("BodyGyro", { MaxTorque = Vector3.one * 1e9, P = 20000, D = 1000, CFrame = hrp.CFrame }, hrp)
		m:Add(bv)
		m:Add(bg)

		State:Save("fly_ps", hum.PlatformStand)
		hum.PlatformStand = true
		m:Add(function()
			local _, _, h = me()
			local v = State:Take("fly_ps")
			if h and v ~= nil then h.PlatformStand = v end
		end)

		local holdY = hrp.Position.Y
		if mode == "down" then
			NoClip:Set("FlyDown", true)
			m:Add(function() NoClip:Set("FlyDown", false) end)
			holdY = (groundY(hrp) or holdY) - State.Cfg.DownDepth
		end
		-- úp mặt = -90 độ quanh X, ngửa mặt = +90 độ; yaw lấy từ camera nên camera giữ nguyên
		local tilt = (mode == "dron" and -math.pi / 2) or (mode == "down" and math.pi / 2) or 0

		m:Add(RunService.Heartbeat:Connect(function(dt)
			local _, r, h = me()
			local c = cam()
			if not r or not h or not c or h.Health <= 0 then return end
			local look = c.CFrame.LookVector
			bg.CFrame = CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0) * CFrame.Angles(tilt, 0, 0)

			local sp = State.Cfg.FlySpeed
			local inp = Move:Vert()
			local dir = h.MoveDirection
			local vy = 0
			if mode == "air" then
				vy = inp * sp
			elseif mode == "dron" then
				if inp ~= 0 then State:SetCfg("DroneHeight", State.Cfg.DroneHeight + inp * 6 * dt) end
				local g = groundY(r)
				local ty
				if g then
					ty = g + State.Cfg.DroneHeight
					holdY = ty
				else
					holdY += inp * 6 * dt
					ty = holdY
				end
				vy = clamp((ty - r.Position.Y) * 5, -sp, sp) -- bay lên/xuống từ từ
			else -- down
				holdY += inp * math.min(sp, 40) * dt
				vy = clamp((holdY - r.Position.Y) * 5, -sp, sp)
			end
			bv.Velocity = Vector3.new(dir.X * sp, vy, dir.Z * sp)
		end))
	end)
end

local NV_PROPS = { "Brightness", "ClockTime", "FogStart", "FogEnd", "Ambient", "OutdoorAmbient", "GlobalShadows", "ExposureCompensation" }

local World = {}
function World:Init(root)
	-- Phím E / Q cho bay lên / xuống (trên mobile dùng nút ▲ ▼)
	root:Add(UIS.InputBegan:Connect(function(i, gp)
		if gp then return end
		if i.KeyCode == Enum.KeyCode.E then Move.keyUp = true end
		if i.KeyCode == Enum.KeyCode.Q then Move.keyDown = true end
	end))
	root:Add(UIS.InputEnded:Connect(function(i)
		if i.KeyCode == Enum.KeyCode.E then Move.keyUp = false end
		if i.KeyCode == Enum.KeyCode.Q then Move.keyDown = false end
	end))

	flight("FlyAir", "air")
	flight("FlyDron", "dron")
	flight("FlyDown", "down")

	feature("NoClip", function(m)
		NoClip:Set("User", true)
		m:Add(function() NoClip:Set("User", false) end)
	end)

	feature("Speed", function(m)
		local _, _, hum = me()
		if hum then State:Save("WalkSpeed", hum.WalkSpeed) end
		m:Add(RunService.Heartbeat:Connect(function()
			local _, _, h = me()
			if h and h.WalkSpeed ~= State.Cfg.WalkSpeed then h.WalkSpeed = State.Cfg.WalkSpeed end
		end))
		m:Add(function()
			local _, _, h = me()
			local v = State:Take("WalkSpeed")
			if h and v ~= nil then h.WalkSpeed = v end
		end)
	end)

	feature("JumpingAir", function(m)
		local last = 0
		m:Add(UIS.JumpRequest:Connect(function()
			local _, r, h = me()
			if not h or not r or h.Health <= 0 then return end
			if os.clock() - last < 0.12 then return end
			last = os.clock()
			local st = h:GetState()
			if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then
				local power = h.UseJumpPower and h.JumpPower or math.sqrt(2 * Workspace.Gravity * h.JumpHeight)
				h:ChangeState(Enum.HumanoidStateType.Jumping)
				local v = r.AssemblyLinearVelocity
				r.AssemblyLinearVelocity = Vector3.new(v.X, math.max(power, 30), v.Z) -- giữ nguyên X/Z -> vẫn di chuyển được
			end
		end))
	end)

	feature("NightVision", function(m)
		local orig, atm = {}, {}
		for _, k in ipairs(NV_PROPS) do orig[k] = Lighting[k] end
		local function apply()
			Lighting.Brightness = 2
			Lighting.ClockTime = 14
			Lighting.FogStart = 1e5
			Lighting.FogEnd = 1e6
			Lighting.Ambient = Color3.fromRGB(200, 200, 200)
			Lighting.OutdoorAmbient = Color3.fromRGB(200, 200, 200)
			Lighting.GlobalShadows = false
			Lighting.ExposureCompensation = 0.5
			for _, a in ipairs(Lighting:GetChildren()) do
				if a:IsA("Atmosphere") then
					if not atm[a] then atm[a] = { a.Density, a.Haze } end
					a.Density, a.Haze = 0, 0
				end
			end
		end
		apply()
		local acc = 0
		m:Add(RunService.Heartbeat:Connect(function(dt) -- game tự reset thì áp lại
			acc += dt
			if acc >= 0.5 then
				acc = 0
				apply()
			end
		end))
		m:Add(function()
			for k, v in pairs(orig) do Lighting[k] = v end
			for a, v in pairs(atm) do
				if a.Parent then a.Density, a.Haze = v[1], v[2] end
			end
		end)
	end)

	feature("FixLag", function(m)
		local log, alive = {}, true
		local function trim(o)
			if o:IsA("ParticleEmitter") or o:IsA("Trail") or o:IsA("Beam") or o:IsA("Smoke")
				or o:IsA("Fire") or o:IsA("Sparkles") or o:IsA("PostEffect") then
				if o.Enabled then
					log[#log + 1] = { o, "Enabled", true }
					o.Enabled = false
				end
			elseif o:IsA("BasePart") and o.CastShadow then
				log[#log + 1] = { o, "CastShadow", true }
				o.CastShadow = false
			end
		end
		local q
		pcall(function()
			q = settings().Rendering.QualityLevel
			settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		end)
		task.spawn(function() -- quét theo lô, yield để không đứng hình
			local n = 0
			for _, r in ipairs({ Workspace, Lighting }) do
				for _, o in ipairs(r:GetDescendants()) do
					if not alive then return end
					trim(o)
					n += 1
					if n % 500 == 0 then task.wait() end
				end
			end
		end)
		m:Add(Workspace.DescendantAdded:Connect(trim))
		m:Add(Lighting.DescendantAdded:Connect(trim))
		m:Add(function()
			alive = false
			for _, r in ipairs(log) do
				if r[1].Parent then pcall(function() r[1][r[2]] = r[3] end) end
			end
			if q then pcall(function() settings().Rendering.QualityLevel = q end) end
		end)
	end)

	-- Hồi sinh: bật lại các tính năng gắn với nhân vật
	local CHAR_FLAGS = { "Speed", "FlyAir", "FlyDron", "FlyDown", "NoClip", "TeleDron", "TeleKill", "JumpingAir", "PlayerBarrier" }
	root:Add(LP.CharacterAdded:Connect(function(char)
		NoClip.snap = {}
		State.Snap.fly_ps, State.Snap.ps_hover = nil, nil
		char:WaitForChild("HumanoidRootPart", 10)
		char:WaitForChild("Humanoid", 10)
		task.wait(0.3)
		for _, f in ipairs(CHAR_FLAGS) do
			if State:Get(f) then
				State:Set(f, false)
				State:Set(f, true)
			end
		end
	end))
end

-- ===================== MODULE: UIController =====================
local UI = {}
local C = {
	bg = Color3.fromRGB(28, 28, 34), bar = Color3.fromRGB(40, 40, 50), row = Color3.fromRGB(38, 38, 46),
	on = Color3.fromRGB(46, 160, 80), off = Color3.fromRGB(150, 50, 50), tab = Color3.fromRGB(55, 55, 70),
	tabOn = Color3.fromRGB(80, 110, 220), text = Color3.fromRGB(235, 235, 240),
}

local function fmt(v) return string.format("%g", math.floor(v * 10 + 0.5) / 10) end

local PAGES = {
	{ "Main", {
		{ "t", "Tele Dron", "TeleDron" },
		{ "n", "Tele Dron - Khoảng cách an toàn", "SafeHeight" },
		{ "t", "Hitbox All Mod", "HitboxAllMod" },
		{ "n", "Hitbox - Phạm vi", "HitboxSize" },
		{ "t", "Tele Kill", "TeleKill" },
		{ "n", "Tele Kill - Khoảng cách sau lưng", "KillOffset" },
		{ "t", "Aimbot", "Aimbot" },
		{ "t", "All Mod Im", "AllModIm" },
		{ "t", "Model Độn Thổ", "ModelDonTho" },
		{ "n", "Độ sâu độn thổ", "BurrowDepth" },
		{ "t", "Model head down", "ModelHeadDown" },
		{ "n", "Độ chôn đầu-vai", "HeadBury" },
		{ "t", "Player Barrier", "PlayerBarrier" },
		{ "n", "Barrier - Kích thước", "BarrierSize" },
		{ "t", "Long Legs", "LongLegs" },
		{ "n", "Long Legs - Độ dài chân", "LegLength" },
		{ "t", "Long Head", "LongHead" },
		{ "n", "Long Head - Độ dài cổ", "NeckLength" },
		{ "n", "Phạm vi mod (Im/Độn Thổ/Head)", "ModRange" },
		{ "n", "Phạm vi quét (Scan Range)", "ScanRange" },
	} },
	{ "Esp", {
		{ "t", "Esp Line", "EspLine" },
		{ "t", "Esp Box", "EspBox" },
		{ "t", "Esp Name", "EspName" },
		{ "t", "Esp Distance", "EspDistance" },
		{ "t", "Esp Hologram", "EspHologram" },
	} },
	{ "Khác", {
		{ "t", "Fly Down", "FlyDown" },
		{ "n", "Fly Down - Độ sâu", "DownDepth" },
		{ "t", "Fly Dron", "FlyDron" },
		{ "n", "Fly Dron - Độ cao", "DroneHeight" },
		{ "t", "No Clip", "NoClip" },
		{ "t", "Fly Air", "FlyAir" },
		{ "n", "Fly Speed", "FlySpeed" },
		{ "t", "Speed", "Speed" },
		{ "n", "Speed - WalkSpeed", "WalkSpeed" },
		{ "t", "Jumping Air", "JumpingAir" },
		{ "t", "Night Vision", "NightVision" },
		{ "t", "Fix Lag", "FixLag" },
	} },
}

function UI:Build(root, onClose)
	local gui = root:Add(new("ScreenGui", { Name = "DbgPanel", ResetOnSpawn = false, DisplayOrder = 100, IgnoreGuiInset = true }, PlayerGui))
	local main = new("Frame", { Size = UDim2.fromOffset(300, 400), Position = UDim2.fromOffset(16, 60), BackgroundColor3 = C.bg, BorderSizePixel = 0, Active = true }, gui)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, main)

	local bar = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = C.bar, BorderSizePixel = 0 }, main)
	new("UICorner", { CornerRadius = UDim.new(0, 8) }, bar)
	new("TextLabel", { Text = "DEBUG PANEL", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.text, BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -80, 1, 0), TextXAlignment = Enum.TextXAlignment.Left }, bar)

	local function barBtn(txt, x)
		return new("TextButton", { Text = txt, Font = Enum.Font.GothamBold, TextSize = 16, TextColor3 = C.text, BackgroundColor3 = C.tab, Size = UDim2.fromOffset(26, 22), Position = UDim2.new(1, x, 0, 5), AutoButtonColor = true }, bar)
	end
	local btnCollapse, btnClose = barBtn("–", -62), barBtn("×", -32)
	new("UICorner", { CornerRadius = UDim.new(0, 5) }, btnCollapse)
	new("UICorner", { CornerRadius = UDim.new(0, 5) }, btnClose)

	local body = new("Frame", { Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 1, -32), BackgroundTransparency = 1 }, main)
	local tabBar = new("Frame", { Size = UDim2.new(1, -12, 0, 28), Position = UDim2.fromOffset(6, 4), BackgroundTransparency = 1 }, body)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, tabBar)

	-- Kéo thả cả bảng (chuột + cảm ứng)
	local dragging, dragStart, startPos
	root:Add(bar.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, i.Position, main.Position
			i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end))
	root:Add(UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))

	-- Thu gọn / mở rộng
	local collapsed = false
	root:Add(btnCollapse.MouseButton1Click:Connect(function()
		collapsed = not collapsed
		body.Visible = not collapsed
		main.Size = collapsed and UDim2.fromOffset(300, 32) or UDim2.fromOffset(300, 400)
		btnCollapse.Text = collapsed and "+" or "–"
	end))
	root:Add(btnClose.MouseButton1Click:Connect(onClose))

	-- Tab + trang cuộn
	local pages, tabs = {}, {}
	local function showTab(name)
		for n, p in pairs(pages) do
			p.Visible = (n == name)
			tabs[n].BackgroundColor3 = (n == name) and C.tabOn or C.tab
		end
	end

	for _, def in ipairs(PAGES) do
		local name, rows = def[1], def[2]
		local tb = new("TextButton", { Text = name, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.text, BackgroundColor3 = C.tab, Size = UDim2.new(1 / 3, -4, 1, 0) }, tabBar)
		new("UICorner", { CornerRadius = UDim.new(0, 6) }, tb)
		tabs[name] = tb

		local page = new("ScrollingFrame", {
			Position = UDim2.fromOffset(6, 38), Size = UDim2.new(1, -12, 1, -44), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 4, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
		}, body)
		new("UIListLayout", { Padding = UDim.new(0, 4) }, page)
		pages[name] = page
		root:Add(tb.MouseButton1Click:Connect(function() showTab(name) end))

		for _, r in ipairs(rows) do
			local kind, label, key = r[1], r[2], r[3]
			local row = new("Frame", { Size = UDim2.new(1, -8, 0, 30), BackgroundColor3 = C.row, BorderSizePixel = 0 }, page)
			new("UICorner", { CornerRadius = UDim.new(0, 6) }, row)
			new("TextLabel", { Text = label, Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C.text, BackgroundTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -76, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd }, row)

			if kind == "t" then
				local b = new("TextButton", { Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text, Size = UDim2.fromOffset(56, 22), Position = UDim2.new(1, -62, 0, 4) }, row)
				new("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
				local function refresh()
					local on = State:Get(key)
					b.Text = on and "ON" or "OFF"
					b.BackgroundColor3 = on and C.on or C.off
				end
				refresh()
				State:Bind("*", function(f) if f == key then refresh() end end)
				root:Add(b.MouseButton1Click:Connect(function() State:Set(key, not State:Get(key)) end))
			else
				local box = new("TextBox", { Text = fmt(State.Cfg[key]), Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text, BackgroundColor3 = C.tab, ClearTextOnFocus = false, Size = UDim2.fromOffset(56, 22), Position = UDim2.new(1, -62, 0, 4) }, row)
				new("UICorner", { CornerRadius = UDim.new(0, 5) }, box)
				root:Add(box.FocusLost:Connect(function()
					State:SetCfg(key, tonumber(box.Text))
					box.Text = fmt(State.Cfg[key]) -- số không hợp lệ -> trả lại giá trị cũ
				end))
				State:Bind("cfg", function(k) if k == key then box.Text = fmt(State.Cfg[key]) end end)
			end
		end
	end
	showTab("Main")

	-- Cụm nút tăng/giảm độ cao (hiện khi bật bất kỳ chế độ bay nào); giữ nút để di chuyển
	local fly = new("Frame", { Size = UDim2.fromOffset(60, 124), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -20, 0.5, 0), BackgroundTransparency = 1, Visible = false }, gui)
	local function flyBtn(txt, y, flagName)
		local b = new("TextButton", { Text = txt, Font = Enum.Font.GothamBold, TextSize = 24, TextColor3 = C.text, BackgroundColor3 = C.bar, BackgroundTransparency = 0.2, Size = UDim2.fromOffset(60, 58), Position = UDim2.fromOffset(0, y) }, fly)
		new("UICorner", { CornerRadius = UDim.new(0, 10) }, b)
		root:Add(b.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then Move[flagName] = true end
		end))
		root:Add(b.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then Move[flagName] = false end
		end))
	end
	flyBtn("▲", 0, "btnUp")
	flyBtn("▼", 66, "btnDown")
	State:Bind("*", function()
		fly.Visible = State:Get("FlyAir") or State:Get("FlyDron") or State:Get("FlyDown")
		if not fly.Visible then Move.btnUp, Move.btnDown = false, false end
	end)
end

-- ===================== KHỞI TẠO =====================
local root = Maid.new()

local function shutdown()
	local names = {}
	for f in pairs(State.Flags) do names[#names + 1] = f end
	for _, f in ipairs(names) do State:Set(f, false) end
	Esp:Cleanup()
	root:Clean()
end

Scanner:Init(root)
Esp:Init(root)
Combat:Init()
Combat:InitExtra()
World:Init(root)
UI:Build(root, shutdown)

print("[DebugPanel] Sẵn sàng. Phím E/Q hoặc nút ▲▼ để lên/xuống khi bay.")
