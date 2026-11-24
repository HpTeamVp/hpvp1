--[[
	DebugConsole.client.lua  (LocalScript)
	Đặt trong StarterPlayer > StarterPlayerScripts. Dành cho debug / test trong game của bạn.

	Cấu trúc module (đều nằm trong 1 file cho dễ dán, có thể tách thành ModuleScript):
	  Conn / Util -> StateManager -> TargetScanner -> CombatEngine -> EspEngine -> MovementAndWorld -> UIController

	CÁCH CẮM TẤN CÔNG CỦA GAME: sửa hàm Combat.AttackHook(target, mode) (tìm "ATTACK HOOK" bên dưới).
	Ví dụ: tool:Activate(), hoặc FireServer vào RemoteEvent đánh/skill của game bạn.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local LP = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Conn: quản lý kết nối sự kiện theo key, chống rò rỉ khi bật/tắt nhiều lần
--------------------------------------------------------------------------------
local Conn, _store = {}, {}
function Conn.drop(key)
	local c = _store[key]
	if c then c:Disconnect() _store[key] = nil end
end
function Conn.set(key, signal, fn) -- luôn ngắt kết nối cũ cùng key trước khi nối mới
	Conn.drop(key)
	_store[key] = signal:Connect(fn)
end
function Conn.has(key) return _store[key] ~= nil end
function Conn.dropAll() for k in pairs(_store) do Conn.drop(k) end end

--------------------------------------------------------------------------------
-- Util
--------------------------------------------------------------------------------
local Util = {}
function Util.hum()
	local c = LP.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if h and h.Health > 0 then return h end
end
function Util.hrp()
	local c = LP.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
function Util.dist(pos)
	local r = Util.hrp()
	return r and (r.Position - pos).Magnitude or math.huge
end
function Util.safe(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then warn("[DebugConsole] " .. tostring(err)) end
end

--------------------------------------------------------------------------------
-- StateManager: cờ bật/tắt, cấu hình, snapshot giá trị gốc
--------------------------------------------------------------------------------
local State = {
	Flags = {},
	Config = {
		ScanRange = 150, ScanInterval = 0.15,
		SafeHeight = 12,      -- khoảng cách an toàn phía trên mục tiêu (Tele Dron)
		KillDistance = 4,     -- đứng sau lưng mục tiêu (Tele Kill)
		DroneHeight = 6,      -- Fly Dron mặc định 6
		FlyDownDepth = 6,     -- độ sâu dưới mặt đất (Fly Down)
		FlySpeed = 60, WalkSpeed = 40,
		HitboxSize = 25, AimSmooth = 0.35, AttackInterval = 0.12, HoverRate = 15,
		BarrierRadius = 8, LongLegsScale = 3, LongHeadHeight = 3,
	},
	Runtime = { Vertical = 0 }, -- -1 / 0 / 1: nút giữ để tăng/giảm độ cao
	_snap = {}, _listeners = {},
}
-- Các nhóm loại trừ: bật cái này thì tắt các cái còn lại trong nhóm
local EXCLUSIVE = { { "FlyAir", "FlyDron", "FlyDown" }, { "TeleDron", "TeleKill" } }
local F, Cfg, RT = State.Flags, State.Config, State.Runtime

function State.listen(flag, fn)
	State._listeners[flag] = State._listeners[flag] or {}
	table.insert(State._listeners[flag], fn)
end
function State.set(flag, value)
	value = value and true or false
	if F[flag] == value then return end
	if value then
		for _, group in EXCLUSIVE do
			if table.find(group, flag) then
				for _, other in group do
					if other ~= flag then State.set(other, false) end
				end
			end
		end
	end
	F[flag] = value
	for _, fn in State._listeners[flag] or {} do Util.safe(fn, value) end
end
function State.save(key, getter) -- chỉ lưu lần đầu, không ghi đè bản gốc
	if State._snap[key] == nil then State._snap[key] = { v = getter() } end
end
function State.take(key) -- lấy và xóa snapshot
	local s = State._snap[key]
	State._snap[key] = nil
	return s and s.v
end

--------------------------------------------------------------------------------
-- TargetScanner: quét bằng GetPartBoundsInRadius + cache theo ScanInterval
--------------------------------------------------------------------------------
local Scanner = { cache = {}, last = 0 }
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude

-- Trả về humanoid, root nếu Model hợp lệ (NPC/Mob còn sống, không phải người chơi)
function Scanner.validate(model)
	if not model or not model.Parent or not model:IsA("Model") then return nil end
	if model == LP.Character or Players:GetPlayerFromCharacter(model) then return nil end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return nil end
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not root then return nil end
	return hum, root
end

function Scanner.get(force)
	local now = os.clock()
	if not force and now - Scanner.last < Cfg.ScanInterval then return Scanner.cache end
	Scanner.last = now
	local myRoot = Util.hrp()
	local list = {}
	if myRoot then
		overlap.FilterDescendantsInstances = { LP.Character }
		local seen = {}
		for _, part in Workspace:GetPartBoundsInRadius(myRoot.Position, Cfg.ScanRange, overlap) do
			local m = part
			while m and m ~= Workspace do -- đi lên tới Model có Humanoid
				if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then break end
				m = m.Parent
			end
			if m and m ~= Workspace and not seen[m] then
				seen[m] = true
				local hum, root = Scanner.validate(m)
				if hum then
					local d = (root.Position - myRoot.Position).Magnitude
					if d <= Cfg.ScanRange then
						-- khả năng tiếp cận: bị che thì cộng phạt khoảng cách để ưu tiên mục tiêu thấy được
						losParams.FilterDescendantsInstances = { LP.Character, m }
						local blocked = Workspace:Raycast(myRoot.Position, root.Position - myRoot.Position, losParams)
						table.insert(list, { model = m, root = root, hum = hum, dist = d, score = d + (blocked and 25 or 0) })
					end
				end
			end
		end
		table.sort(list, function(a, b) return a.score < b.score end)
	end
	Scanner.cache = list
	return list
end

--------------------------------------------------------------------------------
-- CombatEngine
--------------------------------------------------------------------------------
local Combat = { lock = nil, lastAtk = 0, lastSwitch = 0 }

-- ===== ATTACK HOOK: cắm cơ chế đánh/bắn của game vào đây =====
-- target: Model mục tiêu; mode: "TeleDron" | "TeleKill"
-- Mặc định: kích hoạt Tool đang cầm. Nếu game dùng RemoteEvent, ví dụ:
--   game.ReplicatedStorage.Remotes.Attack:FireServer(target)
Combat.AttackHook = function(target, mode)
	local tool = LP.Character and LP.Character:FindFirstChildOfClass("Tool")
	if tool then tool:Activate() end
end

function Combat.attack(target, mode)
	local now = os.clock()
	if now - Combat.lastAtk < Cfg.AttackInterval then return end
	Combat.lastAtk = now
	Util.safe(Combat.AttackHook, target, mode)
end

-- Khóa mục tiêu tạm thời: giữ nếu còn sống & trong tầm, ngược lại tự chuyển sang mục tiêu gần nhất
function Combat.pick()
	local lock = Combat.lock
	if lock then
		local hum, root = Scanner.validate(lock)
		if hum and Util.dist(root.Position) <= Cfg.ScanRange then return lock, root end
		Combat.lock = nil
	end
	local best = Scanner.get(true)[1]
	if best then
		Combat.lock = best.model
		Combat.lastSwitch = os.clock()
		return best.model, best.root
	end
end

local function combatStep()
	if not (F.TeleDron or F.TeleKill) then return end
	local hrp = Util.hrp()
	if not hrp then return end
	local model, root = Combat.pick()
	if not model then return end
	local pos, mode
	if F.TeleDron then
		pos = root.Position + Vector3.new(0, Cfg.SafeHeight, 0) -- lơ lửng trên đầu mob, né cận chiến
		mode = "TeleDron"
	else
		pos = root.Position - root.CFrame.LookVector * Cfg.KillDistance
		mode = "TeleKill"
	end
	-- upVector tùy chọn tránh lỗi suy biến khi nhìn thẳng xuống
	hrp.CFrame = CFrame.lookAt(pos, root.Position, Vector3.new(0, 0, -1))
	hrp.AssemblyLinearVelocity = Vector3.zero -- triệt tiêu lực rơi / đẩy lùi
	hrp.AssemblyAngularVelocity = Vector3.zero
	Combat.attack(model, mode)
end

-- Aimbot: lerp camera, có ramp-up sau khi đổi mục tiêu để chống giật
local aimBlend, aimLast = 0, nil
local function aimStep(dt)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	local model, root = Combat.pick()
	if not model then aimLast = nil return end
	if model ~= aimLast then aimLast, aimBlend = model, 0 end
	aimBlend = math.min(1, aimBlend + dt / 0.15)
	local part = model:FindFirstChild("Head") or root
	local want = CFrame.lookAt(cam.CFrame.Position, part.Position)
	local alpha = math.clamp(Cfg.AimSmooth * aimBlend * (dt * 60), 0, 1)
	cam.CFrame = cam.CFrame:Lerp(want, alpha)
end

-- Hitbox All Mod + All Mod Im: chạy theo nhịp ScanInterval, lưu/khôi phục giá trị gốc
local hbOrig = setmetatable({}, { __mode = "k" })   -- root -> {Size, CanCollide, Transparency, Massless}
local imOrig = setmetatable({}, { __mode = "k" })   -- humanoid -> {WalkSpeed, JumpPower, JumpHeight, AutoRotate}

local function restoreHitbox(root)
	local o = hbOrig[root]
	if o and root.Parent then
		root.Size, root.CanCollide, root.Transparency, root.Massless = o.Size, o.CanCollide, o.Transparency, o.Massless
	end
	hbOrig[root] = nil
end
local function restoreMob(hum)
	local o = imOrig[hum]
	if o and hum.Parent then
		hum.WalkSpeed, hum.JumpPower, hum.JumpHeight, hum.AutoRotate = o.WalkSpeed, o.JumpPower, o.JumpHeight, o.AutoRotate
	end
	imOrig[hum] = nil
end

-- Client-side visual effects for Main tab.
-- These edits are local only; server-authoritative damage/hitboxes are unchanged.
local shapeOrig = setmetatable({}, { __mode = "k" }) -- BasePart -> original Size/CFrame
local barrierPart, barrierForceField
local barrierCharacter

local function restoreShape(part)
	local original = shapeOrig[part]
	if original and part.Parent then
		part.Size = original.Size
		part.CFrame = original.CFrame
	end
	shapeOrig[part] = nil
end

local function restoreModelShapes(model)
	for part in pairs(shapeOrig) do
		if part:IsDescendantOf(model) then restoreShape(part) end
	end
end

local function applyScaledPart(part, size, offset)
	if not shapeOrig[part] then
		shapeOrig[part] = { Size = part.Size, CFrame = part.CFrame }
	end
	local original = shapeOrig[part]
	part.Size = size(original.Size)
	part.CFrame = original.CFrame * CFrame.new(offset(original.Size))
end

local function updatePlayerBarrier()
	local character = LP.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not F.PlayerBarrier or not root then
		if barrierPart then barrierPart:Destroy(); barrierPart = nil end
		if barrierForceField then barrierForceField:Destroy(); barrierForceField = nil end
		barrierCharacter = nil
		return
	end

	if barrierCharacter ~= character then
		if barrierPart then barrierPart:Destroy() end
		if barrierForceField then barrierForceField:Destroy() end
		barrierCharacter = character

		-- Local visual indicator only. A client-created ForceField cannot
		-- prevent damage that is validated and applied by the server.
		barrierForceField = Instance.new("ForceField")
		barrierForceField.Visible = true
		barrierForceField.Parent = character

		barrierPart = Instance.new("Part")
		barrierPart.Name = "LocalPlayerBarrierVisual"
		barrierPart.Shape = Enum.PartType.Ball
		barrierPart.Material = Enum.Material.ForceField
		barrierPart.Color = Color3.fromRGB(70, 170, 255)
		barrierPart.Transparency = 0.78
		barrierPart.Anchored = true
		-- Client-side collision shell: may collide with locally simulated NPCs,
		-- but cannot guarantee blocking server-owned/network-owned NPCs.
		barrierPart.CanCollide = true
		barrierPart.CanTouch = false
		barrierPart.CanQuery = true
		barrierPart.CastShadow = false
		barrierPart.Parent = Workspace
	end

	local diameter = Cfg.BarrierRadius * 2
	barrierPart.Size = Vector3.new(diameter, diameter, diameter)
	barrierPart.CFrame = root.CFrame
end

local function applyMobShapes(model)
	local head = model:FindFirstChild("Head")
	if F.LongHead and head and head:IsA("BasePart") then
		local factor = Cfg.LongHeadHeight
		applyScaledPart(
			head,
			function(original) return Vector3.new(original.X, original.Y * factor, original.Z) end,
			function(original) return Vector3.new(0, original.Y * (factor - 1) / 2, 0) end
		)
	elseif head and shapeOrig[head] then
		restoreShape(head)
	end

	local legNames = {
		["Left Leg"] = true, ["Right Leg"] = true,
		["LeftUpperLeg"] = true, ["RightUpperLeg"] = true,
		["LeftLowerLeg"] = true, ["RightLowerLeg"] = true,
		["LeftFoot"] = true, ["RightFoot"] = true,
	}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and legNames[part.Name] then
			if F.LongLegs then
				local factor = Cfg.LongLegsScale
				applyScaledPart(
					part,
					function(original) return Vector3.new(original.X, original.Y * factor, original.Z) end,
					function(original) return Vector3.new(0, -original.Y * (factor - 1) / 2, 0) end
				)
			elseif shapeOrig[part] then
				restoreShape(part)
			end
		end
	end
end

local function restoreAllMobShapes()
	for part in pairs(shapeOrig) do restoreShape(part) end
end

local modAcc = 0
local function modStep(dt)
	modAcc += dt
	if modAcc < 0.2 then return end
	modAcc = 0
	local inRange = {}
	for _, t in Scanner.get() do
		inRange[t.root], inRange[t.hum] = true, true
		if F.LongLegs or F.LongHead then applyMobShapes(t.model) else restoreModelShapes(t.model) end
		if F.HitboxAll then
			if not hbOrig[t.root] then
				hbOrig[t.root] = { Size = t.root.Size, CanCollide = t.root.CanCollide, Transparency = t.root.Transparency, Massless = t.root.Massless }
			end
			-- phóng to HRP: phủ cả vùng dưới đất / sau tường để đòn đánh vẫn trúng
			t.root.Size = Vector3.one * Cfg.HitboxSize
			t.root.CanCollide = false
			t.root.Transparency = 0.8
			t.root.Massless = true
		end
		if F.AllModIm then
			if not imOrig[t.hum] then
				imOrig[t.hum] = { WalkSpeed = t.hum.WalkSpeed, JumpPower = t.hum.JumpPower, JumpHeight = t.hum.JumpHeight, AutoRotate = t.hum.AutoRotate }
			end
			-- Giữ mob đứng yên (không di chuyển / không đuổi được người chơi)
			t.hum.WalkSpeed, t.hum.JumpPower, t.hum.JumpHeight, t.hum.AutoRotate = 0, 0, 0, false
		end
	end
	-- trả lại mục tiêu đã ra ngoài tầm / chết / tắt tính năng
	for root in pairs(hbOrig) do if not F.HitboxAll or not inRange[root] then restoreHitbox(root) end end
	for hum in pairs(imOrig) do if not F.AllModIm or not inRange[hum] then restoreMob(hum) end end
	for part in pairs(shapeOrig) do
		local model = part:FindFirstAncestorOfClass("Model")
		if not (F.LongLegs or F.LongHead) or not model or not Scanner.validate(model) then restoreShape(part) end
	end
	updatePlayerBarrier()
end

local function updateCombatConns()
	if F.TeleDron or F.TeleKill then Conn.set("combat", RunService.Heartbeat, combatStep) else Conn.drop("combat") end
	if F.Aimbot then Conn.set("aim", RunService.RenderStepped, aimStep) else Conn.drop("aim") aimLast = nil end
	if F.HitboxAll or F.AllModIm or F.LongLegs or F.LongHead or F.PlayerBarrier then
		Conn.set("mods", RunService.Heartbeat, modStep)
	else
		Conn.drop("mods")
		for r in pairs(hbOrig) do restoreHitbox(r) end
		for h in pairs(imOrig) do restoreMob(h) end
		restoreAllMobShapes()
		updatePlayerBarrier()
	end
end
for _, f in { "TeleDron", "TeleKill", "Aimbot", "HitboxAll", "AllModIm", "LongLegs", "LongHead", "PlayerBarrier" } do
	State.listen(f, function()
		if not (F.TeleDron or F.TeleKill) then Combat.lock = nil end
		updateCombatConns()
	end)
end

--------------------------------------------------------------------------------
-- EspEngine (dựng bằng GUI + Highlight, không phụ thuộc Drawing API)
--------------------------------------------------------------------------------
local Esp = { entries = {}, items = {}, itemAcc = 0 }
local espGui, hlFolder

local function ensureEspLayer()
	if espGui and espGui.Parent then return end
	espGui = Instance.new("ScreenGui")
	espGui.Name, espGui.ResetOnSpawn, espGui.IgnoreGuiInset, espGui.DisplayOrder = "EspLayer", false, true, 50
	espGui.Parent = LP:WaitForChild("PlayerGui")
	hlFolder = Instance.new("Folder")
	hlFolder.Name = "EspHighlights"
	hlFolder.Parent = Workspace.CurrentCamera
end

local function mkLabel(color)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency, l.TextColor3, l.TextStrokeTransparency = 1, color, 0.3
	l.Font, l.TextSize, l.Size, l.AnchorPoint = Enum.Font.GothamBold, 13, UDim2.fromOffset(160, 14), Vector2.new(0.5, 1)
	l.Parent = espGui
	return l
end

local function newEntry()
	return {}
end
local function dropField(e, k)
	if e[k] then e[k]:Destroy() e[k] = nil end
end
local function dropEntry(model)
	local e = Esp.entries[model]
	if e then
		for k in pairs(e) do dropField(e, k) end
		Esp.entries[model] = nil
	end
end
function Esp.clearAll()
	for m in pairs(Esp.entries) do dropEntry(m) end
	for inst, hl in pairs(Esp.items) do hl:Destroy() Esp.items[inst] = nil end
end

-- 3D bounding box -> hình chữ nhật 2D (World-to-Screen), nil nếu một góc nằm sau camera
local SIGN = { -1, 1 }
local function screenRect(model, cam)
	local cf, size = model:GetBoundingBox()
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, sx in SIGN do for _, sy in SIGN do for _, sz in SIGN do
		local v = cam:WorldToViewportPoint(cf:PointToWorldSpace(Vector3.new(sx * hx, sy * hy, sz * hz)))
		if v.Z <= 0 then return nil end
		minX, maxX = math.min(minX, v.X), math.max(maxX, v.X)
		minY, maxY = math.min(minY, v.Y), math.max(maxY, v.Y)
	end end end
	return minX, minY, maxX, maxY
end

local function espTargetStep(cam)
	local seen = {}
	local vp = cam.ViewportSize
	for _, t in Scanner.get() do
		local model = t.model
		local hum, root = Scanner.validate(model) -- chết/biến mất -> bị loại ngay, entry bị xóa bên dưới
		if hum then
			local dist = Util.dist(root.Position)
			if dist <= Cfg.ScanRange then
				seen[model] = true
				local e = Esp.entries[model] or newEntry()
				Esp.entries[model] = e
				local sp = cam:WorldToViewportPoint(root.Position)
				local onScreen = sp.Z > 0

				-- Line: từ cạnh trên giữa màn hình tới mục tiêu
				if F.EspLine and onScreen then
					if not e.line then
						e.line = Instance.new("Frame")
						e.line.AnchorPoint, e.line.BorderSizePixel = Vector2.new(0.5, 0.5), 0
						e.line.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
						e.line.Parent = espGui
					end
					local a, b = Vector2.new(vp.X / 2, 0), Vector2.new(sp.X, sp.Y)
					local d = b - a
					e.line.Size = UDim2.fromOffset(d.Magnitude, 1.5)
					e.line.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
					e.line.Rotation = math.deg(math.atan2(d.Y, d.X))
				else
					dropField(e, "line")
				end

				-- Box / Name / Distance dùng chung hình chữ nhật 2D
				local needRect = F.EspBox or F.EspName or F.EspDistance
				local x1, y1, x2, y2
				if needRect then x1, y1, x2, y2 = screenRect(model, cam) end
				if x1 and F.EspBox then
					if not e.box then
						e.box = Instance.new("Frame")
						e.box.BackgroundTransparency, e.box.BorderSizePixel = 1, 0
						local s = Instance.new("UIStroke")
						s.Color, s.Thickness = Color3.fromRGB(255, 255, 0), 1.5
						s.Parent = e.box
						e.box.Parent = espGui
					end
					e.box.Position = UDim2.fromOffset(x1, y1)
					e.box.Size = UDim2.fromOffset(x2 - x1, y2 - y1)
				else
					dropField(e, "box")
				end
				if x1 and F.EspName then
					e.name = e.name or mkLabel(Color3.new(1, 1, 1))
					e.name.Text = model.Name
					e.name.Position = UDim2.fromOffset((x1 + x2) / 2, y1 - 2)
				else
					dropField(e, "name")
				end
				if x1 and F.EspDistance then
					e.dist = e.dist or mkLabel(Color3.fromRGB(120, 220, 255))
					e.dist.AnchorPoint = Vector2.new(0.5, 0)
					e.dist.Text = string.format("%.0f studs (%.0f m)", dist, dist * 0.28)
					e.dist.Position = UDim2.fromOffset((x1 + x2) / 2, y2 + 2)
				else
					dropField(e, "dist")
				end

				-- Hologram: Highlight xuyên vật cản
				if F.EspHologram then
					if not e.hl then
						local h = Instance.new("Highlight")
						h.FillColor, h.OutlineColor = Color3.fromRGB(255, 60, 60), Color3.new(1, 1, 1)
						h.FillTransparency, h.DepthMode = 0.6, Enum.HighlightDepthMode.AlwaysOnTop
						h.Adornee, h.Parent = model, hlFolder
						e.hl = h
					end
				else
					dropField(e, "hl")
				end
			end
		end
	end
	for m in pairs(Esp.entries) do if not seen[m] then dropEntry(m) end end
end

-- Esp Workspace: quét an toàn workspace.Item (có thể chưa tồn tại / bị xóa giữa chừng)
local function collectItems(parent, out, depth)
	for _, obj in parent:GetChildren() do
		if obj:IsA("Model") or obj:IsA("BasePart") then
			out[#out + 1] = obj
		elseif depth < 3 and (obj:IsA("Folder") or obj:IsA("Configuration")) then
			collectItems(obj, out, depth + 1)
		end
	end
end
local function itemStep()
	local folder = Workspace:FindFirstChild("Item")
	local want = {}
	if folder then
		local list = {}
		collectItems(folder, list, 0)
		for _, obj in list do
			if obj.Parent then
				local pos = obj:IsA("Model") and obj:GetPivot().Position or obj.Position
				local hum = obj:IsA("Model") and obj:FindFirstChildOfClass("Humanoid")
				if Util.dist(pos) <= Cfg.ScanRange and not (hum and hum.Health <= 0) then
					want[obj] = true
					if not Esp.items[obj] then
						local h = Instance.new("Highlight")
						h.FillColor, h.OutlineColor = Color3.fromRGB(80, 255, 120), Color3.new(1, 1, 1)
						h.FillTransparency, h.DepthMode = 0.6, Enum.HighlightDepthMode.AlwaysOnTop
						h.Adornee, h.Parent = obj, hlFolder
						Esp.items[obj] = h
					end
				end
			end
		end
	end
	for obj, h in pairs(Esp.items) do
		if not want[obj] or not obj.Parent then h:Destroy() Esp.items[obj] = nil end
	end
end

local function espStep(dt)
	local cam = Workspace.CurrentCamera
	if not cam then return end
	ensureEspLayer()
	if F.EspLine or F.EspBox or F.EspName or F.EspDistance or F.EspHologram then
		espTargetStep(cam)
	else
		for m in pairs(Esp.entries) do dropEntry(m) end
	end
	if F.EspWorkspace then
		Esp.itemAcc += dt
		if Esp.itemAcc >= 0.4 then Esp.itemAcc = 0 itemStep() end
	else
		for obj, h in pairs(Esp.items) do h:Destroy() Esp.items[obj] = nil end
	end
end
local ESP_FLAGS = { "EspLine", "EspBox", "EspName", "EspDistance", "EspHologram", "EspWorkspace" }
for _, f in ESP_FLAGS do
	State.listen(f, function()
		local any = false
		for _, k in ESP_FLAGS do any = any or F[k] end
		if any then
			ensureEspLayer()
			Conn.set("esp", RunService.RenderStepped, espStep)
		else
			Conn.drop("esp")
			Esp.clearAll() -- dọn sạch mọi thứ khi tắt hết
		end
	end)
end

--------------------------------------------------------------------------------
-- MovementAndWorld
--------------------------------------------------------------------------------
local Move = { yaw = 0, groundY = 0, noclipReasons = {}, noclipOrig = setmetatable({}, { __mode = "k" }) }

-- NoClip (đếm tham chiếu: Fly Down cũng cần noclip để chui xuống đất)
local function noclipStep()
	local c = LP.Character
	if not c then return end
	for _, p in c:GetDescendants() do
		if p:IsA("BasePart") then
			if Move.noclipOrig[p] == nil then Move.noclipOrig[p] = p.CanCollide end
			p.CanCollide = false
		end
	end
end
local function refreshNoclip()
	if next(Move.noclipReasons) then
		Conn.set("noclip", RunService.Stepped, noclipStep)
	else
		Conn.drop("noclip")
		for p, orig in pairs(Move.noclipOrig) do
			if p.Parent then p.CanCollide = orig end -- khôi phục chính xác trạng thái ban đầu
			Move.noclipOrig[p] = nil
		end
	end
end
function Move.setNoclip(reason, on)
	Move.noclipReasons[reason] = on or nil
	refreshNoclip()
end
State.listen("NoClip", function(on) Move.setNoclip("user", on) end)

-- Fly Air / Fly Dron / Fly Down dùng chung 1 vòng Heartbeat
local rayP = RaycastParams.new()
rayP.FilterType = Enum.RaycastFilterType.Exclude
local function flyStep(dt)
	local hum, hrp = Util.hum(), Util.hrp()
	if not (hum and hrp) then return end
	hum.PlatformStand = true -- tránh Humanoid tự đứng/rơi làm lệch vị trí
	local move, v = hum.MoveDirection, RT.Vertical

	if F.FlyAir then
		-- Trọng lực vẫn kéo xuống 1 chút mỗi bước vật lý, nên không chỉ đặt vận tốc:
		-- ta giữ độ cao mục tiêu Move.airY, chỉ đổi khi bấm lên/xuống, và ghim lại Y mỗi khung hình.
		local pos0 = hrp.Position
		if not Move.airY or Move.airHrp ~= hrp then Move.airY, Move.airHrp = pos0.Y, hrp end
		Move.airY += v * Cfg.FlySpeed * dt
		local look = move.Magnitude > 0.1 and Vector3.new(move.X, 0, move.Z) or nil
		local base = look and CFrame.lookAt(Vector3.new(pos0.X, Move.airY, pos0.Z), Vector3.new(pos0.X + look.X, Move.airY, pos0.Z + look.Z))
			or (hrp.CFrame.Rotation + Vector3.new(pos0.X, Move.airY, pos0.Z))
		hrp.CFrame = base
		-- Y = 0 hoàn toàn: đứng yên giữa trời, không rơi / không trôi
		hrp.AssemblyLinearVelocity = Vector3.new(move.X * Cfg.FlySpeed, 0, move.Z * Cfg.FlySpeed)
		hrp.AssemblyAngularVelocity = Vector3.zero
		return
	end

	-- Dron (úp mặt, cách đất DroneHeight) / Down (ngửa mặt, chìm dưới đất FlyDownDepth)
	local pos = hrp.Position
	rayP.FilterDescendantsInstances = { LP.Character }
	local originY = pos.Y + (F.FlyDown and Cfg.FlyDownDepth or 0) + 3
	local hit = Workspace:Raycast(Vector3.new(pos.X, originY, pos.Z), Vector3.new(0, -600, 0), rayP)
	if hit then Move.groundY = hit.Position.Y end -- không thấy đất thì giữ giá trị cũ => không rơi
	local wantY
	if F.FlyDron then
		Cfg.DroneHeight = math.clamp(Cfg.DroneHeight + v * Cfg.HoverRate * dt, 1, 300)
		wantY = Move.groundY + Cfg.DroneHeight
	else
		-- depth > 0: dưới đất; depth <= 0: ngang/trên mặt đất (▲ giảm depth để đi lên, không bị chặn ở mặt đất)
		Cfg.FlyDownDepth = math.clamp(Cfg.FlyDownDepth - v * math.max(Cfg.HoverRate, Cfg.FlySpeed * 0.5) * dt, -150, 150)
		wantY = Move.groundY - Cfg.FlyDownDepth
	end
	if move.Magnitude > 0.1 then Move.yaw = math.atan2(-move.X, -move.Z) end
	local newPos = Vector3.new(
		pos.X + move.X * Cfg.FlySpeed * dt,
		pos.Y + (wantY - pos.Y) * math.min(1, dt * 10),
		pos.Z + move.Z * Cfg.FlySpeed * dt)
	local pitch = F.FlyDron and -math.pi / 2 or math.pi / 2
	hrp.CFrame = CFrame.new(newPos) * CFrame.Angles(0, Move.yaw, 0) * CFrame.Angles(pitch, 0, 0)
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	-- Camera không bị chỉnh => giữ nguyên góc camera gốc
end

local function refreshFly()
	Move.airY = nil -- lấy lại độ cao hiện tại mỗi lần bật/tắt chế độ bay
	if F.FlyAir or F.FlyDron or F.FlyDown then
		local cam = Workspace.CurrentCamera
		if cam then local l = cam.CFrame.LookVector Move.yaw = math.atan2(-l.X, -l.Z) end
		State.save("PlatformStand", function() local h = Util.hum() return h and h.PlatformStand or false end)
		Conn.set("fly", RunService.Heartbeat, flyStep)
	else
		Conn.drop("fly")
		RT.Vertical = 0
		local h, r = Util.hum(), Util.hrp()
		if h then h.PlatformStand = State.take("PlatformStand") or false end
		if r then -- đứng thẳng lại
			r.CFrame = CFrame.new(r.Position) * CFrame.Angles(0, Move.yaw, 0)
			r.AssemblyLinearVelocity = Vector3.zero
		end
	end
end
for _, f in { "FlyAir", "FlyDron", "FlyDown" } do
	State.listen(f, function()
		Move.setNoclip("FlyDown", F.FlyDown)
		refreshFly()
	end)
end

-- Speed
local spd = {}
State.listen("Speed", function(on)
	if on then
		Conn.set("speed", RunService.Heartbeat, function()
			local h = Util.hum()
			if not h then return end
			if spd.hum ~= h then spd.hum, spd.orig = h, h.WalkSpeed end -- snapshot theo từng nhân vật
			h.WalkSpeed = Cfg.WalkSpeed
		end)
	else
		Conn.drop("speed")
		if spd.hum and spd.hum.Parent then spd.hum.WalkSpeed = spd.orig or 16 end
		spd.hum = nil
	end
end)

-- Jumping Air
local lastJump = 0
State.listen("JumpAir", function(on)
	if on then
		Conn.set("jump", UIS.JumpRequest, function()
			local h = Util.hum()
			if h and os.clock() - lastJump > 0.15 then
				lastJump = os.clock()
				h.PlatformStand = false
				h:ChangeState(Enum.HumanoidStateType.Jumping) -- không khóa trạng thái => vẫn di chuyển được
			end
		end)
	else
		Conn.drop("jump")
	end
end)

-- Night Vision
State.listen("NightVision", function(on)
	if on then
		State.save("Night", function()
			local s = {}
			for _, k in { "Brightness", "ClockTime", "FogStart", "FogEnd", "GlobalShadows", "Ambient", "OutdoorAmbient", "ExposureCompensation" } do s[k] = Lighting[k] end
			s.atmo = {}
			for _, a in Lighting:GetChildren() do
				if a:IsA("Atmosphere") then s.atmo[a] = { a.Density, a.Haze } end
			end
			return s
		end)
		Lighting.Brightness, Lighting.ClockTime, Lighting.FogStart, Lighting.FogEnd = 2, 14, 1e5, 1e6
		Lighting.GlobalShadows, Lighting.Ambient, Lighting.OutdoorAmbient = false, Color3.new(1, 1, 1), Color3.new(1, 1, 1)
		for _, a in Lighting:GetChildren() do
			if a:IsA("Atmosphere") then a.Density, a.Haze = 0, 0 end
		end
	else
		local s = State.take("Night")
		if s then
			for k, v in pairs(s) do if k ~= "atmo" then Lighting[k] = v end end
			for a, vals in pairs(s.atmo) do if a.Parent then a.Density, a.Haze = vals[1], vals[2] end end
		end
	end
end)

-- Fix Lag (disable có snapshot, không xóa => khôi phục được)
local lagOrig = setmetatable({}, { __mode = "k" })
local LAG_CLASSES = { "ParticleEmitter", "Trail", "Beam", "Smoke", "Fire", "Sparkles", "BloomEffect", "BlurEffect", "SunRaysEffect", "DepthOfFieldEffect" }
local lagToken = 0
local function lagHandle(inst)
	for _, cls in LAG_CLASSES do
		if inst:IsA(cls) then
			if lagOrig[inst] == nil then lagOrig[inst] = inst.Enabled end
			inst.Enabled = false
			return
		end
	end
end
State.listen("FixLag", function(on)
	lagToken += 1
	local token = lagToken
	if on then
		State.save("Lag", function()
			local ok, q = pcall(function() return settings().Rendering.QualityLevel end)
			return { shadows = Lighting.GlobalShadows, quality = ok and q or nil }
		end)
		Lighting.GlobalShadows = false
		pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
		for _, c in Lighting:GetChildren() do lagHandle(c) end
		Conn.set("lagAdded", Workspace.DescendantAdded, lagHandle)
		task.spawn(function() -- quét theo lô, có yield để không đơ khung hình
			local n = 0
			for _, d in Workspace:GetDescendants() do
				if token ~= lagToken then return end
				lagHandle(d)
				n += 1
				if n % 400 == 0 then task.wait() end
			end
		end)
	else
		Conn.drop("lagAdded")
		for inst, prev in pairs(lagOrig) do
			if inst.Parent then inst.Enabled = prev end
			lagOrig[inst] = nil
		end
		local s = State.take("Lag")
		if s then
			Lighting.GlobalShadows = s.shadows
			if s.quality then pcall(function() settings().Rendering.QualityLevel = s.quality end) end
		end
	end
end)

-- Hồi sinh: bỏ snapshot nhân vật cũ, noclip áp lại ở nhân vật mới
LP.CharacterAdded:Connect(function()
	table.clear(Move.noclipOrig)
	RT.Vertical = 0
end)

--------------------------------------------------------------------------------
-- UIController
--------------------------------------------------------------------------------
local UI = { refreshers = {} }
local C = {
	bg = Color3.fromRGB(22, 22, 28), bar = Color3.fromRGB(34, 34, 44), row = Color3.fromRGB(32, 32, 40),
	on = Color3.fromRGB(60, 180, 100), off = Color3.fromRGB(150, 60, 60), text = Color3.fromRGB(235, 235, 240),
	accent = Color3.fromRGB(90, 120, 255),
}
local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function round(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 6) }, o) end

local gui = new("ScreenGui", { Name = "DebugConsole", ResetOnSpawn = false, DisplayOrder = 100, IgnoreGuiInset = true }, LP:WaitForChild("PlayerGui"))
local main = new("Frame", { Size = UDim2.fromOffset(300, 410), Position = UDim2.fromOffset(20, 80), BackgroundColor3 = C.bg, BorderSizePixel = 0 }, gui)
round(main, 10)
local top = new("Frame", { Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = C.bar, BorderSizePixel = 0 }, main)
round(top, 10)
new("TextLabel", { Size = UDim2.new(1, -80, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1, Text = "Debug Console", TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left }, top)
local btnCollapse = new("TextButton", { Size = UDim2.fromOffset(28, 24), Position = UDim2.new(1, -66, 0, 4), BackgroundColor3 = C.row, Text = "—", TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 14 }, top)
local btnClose = new("TextButton", { Size = UDim2.fromOffset(28, 24), Position = UDim2.new(1, -34, 0, 4), BackgroundColor3 = C.off, Text = "X", TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 14 }, top)
round(btnCollapse, 5) round(btnClose, 5)
local content = new("Frame", { Size = UDim2.new(1, 0, 1, -32), Position = UDim2.fromOffset(0, 32), BackgroundTransparency = 1 }, main)

-- Kéo thả menu bằng thanh tiêu đề (chuột + cảm ứng)
top.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		local startPos, origin = input.Position, main.Position
		Conn.set("uiDrag", UIS.InputChanged, function(i)
			if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
				local d = i.Position - startPos
				main.Position = UDim2.new(origin.X.Scale, origin.X.Offset + d.X, origin.Y.Scale, origin.Y.Offset + d.Y)
			end
		end)
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then Conn.drop("uiDrag") end
		end)
	end
end)

local collapsed = false
btnCollapse.MouseButton1Click:Connect(function()
	collapsed = not collapsed
	content.Visible = not collapsed
	main.Size = collapsed and UDim2.fromOffset(300, 32) or UDim2.fromOffset(300, 410)
end)

-- Tab
local tabBar = new("Frame", { Size = UDim2.new(1, -16, 0, 28), Position = UDim2.fromOffset(8, 4), BackgroundTransparency = 1 }, content)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, tabBar)
local pages, tabBtns = {}, {}
local function selectTab(name)
	for n, p in pairs(pages) do p.Visible = (n == name) end
	for n, b in pairs(tabBtns) do b.BackgroundColor3 = (n == name) and C.accent or C.row end
end
for _, name in { "Main", "Esp", "Khác" } do
	local b = new("TextButton", { Size = UDim2.new(1 / 3, -4, 1, 0), BackgroundColor3 = C.row, Text = name, TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 13 }, tabBar)
	round(b, 6)
	tabBtns[name] = b
	local p = new("ScrollingFrame", {
		Size = UDim2.new(1, -16, 1, -42), Position = UDim2.fromOffset(8, 38), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 4, AutomaticCanvasSize = Enum.AutomaticSize.Y, CanvasSize = UDim2.new(), Visible = false,
	}, content)
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, p)
	pages[name] = p
	b.MouseButton1Click:Connect(function() selectTab(name) end)
end

-- Hàng chức năng + nút ▲▼ để sắp xếp lại thứ tự tự do
local function reorder(page, row, dir)
	local rows = {}
	for _, r in page:GetChildren() do if r:IsA("Frame") then rows[#rows + 1] = r end end
	table.sort(rows, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	local i = table.find(rows, row)
	local j = i and i + dir
	if i and rows[j] then row.LayoutOrder, rows[j].LayoutOrder = rows[j].LayoutOrder, row.LayoutOrder end
end
local orderCounter = 0
local function addRow(page, label)
	orderCounter += 10
	local row = new("Frame", { Size = UDim2.new(1, -6, 0, 32), BackgroundColor3 = C.row, LayoutOrder = orderCounter, BorderSizePixel = 0 }, page)
	round(row)
	new("TextLabel", { Size = UDim2.new(1, -110, 1, 0), Position = UDim2.fromOffset(8, 0), BackgroundTransparency = 1, Text = label, TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left }, row)
	for k, dir in ipairs({ -1, 1 }) do
		local b = new("TextButton", { Size = UDim2.fromOffset(18, 24), Position = UDim2.new(1, -44 + (k - 1) * 20, 0, 4), BackgroundColor3 = C.bar, Text = dir < 0 and "▲" or "▼", TextColor3 = C.text, TextSize = 9, Font = Enum.Font.GothamBold }, row)
		round(b, 4)
		b.MouseButton1Click:Connect(function() reorder(page, row, dir) end)
	end
	return row
end
local function toggleRow(tab, label, flag)
	local row = addRow(pages[tab], label)
	local btn = new("TextButton", { Size = UDim2.fromOffset(50, 24), Position = UDim2.new(1, -98, 0, 4), Text = "OFF", TextColor3 = C.text, BackgroundColor3 = C.off, Font = Enum.Font.GothamBold, TextSize = 12 }, row)
	round(btn, 5)
	local function paint(on) btn.Text, btn.BackgroundColor3 = on and "ON" or "OFF", on and C.on or C.off end
	State.listen(flag, paint) -- giữ UI đồng bộ cả khi bị tắt do loại trừ lẫn nhau
	btn.MouseButton1Click:Connect(function() State.set(flag, not F[flag]) end)
end
local function numberRow(tab, label, key, min, max)
	local row = addRow(pages[tab], label)
	local box = new("TextBox", { Size = UDim2.fromOffset(50, 24), Position = UDim2.new(1, -98, 0, 4), Text = tostring(Cfg[key]), TextColor3 = C.text, BackgroundColor3 = C.bar, Font = Enum.Font.Gotham, TextSize = 12, ClearTextOnFocus = false }, row)
	round(box, 5)
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then Cfg[key] = math.clamp(n, min, max) end -- chỉ nhận số hợp lệ
		box.Text = tostring(math.floor(Cfg[key] * 10) / 10)
	end)
	table.insert(UI.refreshers, function() if not box:IsFocused() then box.Text = tostring(math.floor(Cfg[key] * 10) / 10) end end)
end

toggleRow("Main", "Tele Dron", "TeleDron")
numberRow("Main", "  An toàn Tele Dron", "SafeHeight", 3, 100)
toggleRow("Main", "Hitbox All Mod", "HitboxAll")
numberRow("Main", "  Cỡ Hitbox", "HitboxSize", 2, 200)
toggleRow("Main", "All Mod Im", "AllModIm")
toggleRow("Main", "Player Barrier (Local Collision)", "PlayerBarrier")
numberRow("Main", "  Barrier Radius", "BarrierRadius", 2, 30)
toggleRow("Main", "Long Legs (Mob)", "LongLegs")
numberRow("Main", "  Long Legs Scale", "LongLegsScale", 1, 10)
toggleRow("Main", "Long Head (Mob)", "LongHead")
numberRow("Main", "  Long Head Height", "LongHeadHeight", 1, 10)
toggleRow("Main", "Tele Kill", "TeleKill")
toggleRow("Main", "Aimbot", "Aimbot")
numberRow("Main", "  Phạm vi quét", "ScanRange", 10, 500)

toggleRow("Esp", "Esp Line", "EspLine")
toggleRow("Esp", "Esp Box", "EspBox")
toggleRow("Esp", "Esp Name", "EspName")
toggleRow("Esp", "Esp Distance", "EspDistance")
toggleRow("Esp", "Esp Hologram", "EspHologram")
toggleRow("Esp", "Esp Workspace", "EspWorkspace")

toggleRow("Khác", "Fly Down", "FlyDown")
numberRow("Khác", "  Độ sâu Fly Down", "FlyDownDepth", -150, 150)
toggleRow("Khác", "Fly Dron", "FlyDron")
numberRow("Khác", "  Độ cao Fly Dron", "DroneHeight", 1, 300)
toggleRow("Khác", "No Clip", "NoClip")
toggleRow("Khác", "Fly Air", "FlyAir")
numberRow("Khác", "Fly Speed", "FlySpeed", 1, 500)
toggleRow("Khác", "Speed", "Speed")
numberRow("Khác", "  WalkSpeed", "WalkSpeed", 1, 500)
toggleRow("Khác", "Jumping Air", "JumpAir")
toggleRow("Khác", "Night Vision", "NightVision")
toggleRow("Khác", "Fix Lag", "FixLag")
selectTab("Main")

-- Cụm nút tăng/giảm độ cao trên màn hình (hiện khi bật Fly Air / Dron / Down)
local pad = new("Frame", { Size = UDim2.fromOffset(60, 124), Position = UDim2.new(1, -80, 0.5, -62), BackgroundTransparency = 1, Visible = false }, gui)
local function padBtn(text, y, val)
	local b = new("TextButton", { Size = UDim2.fromOffset(60, 56), Position = UDim2.fromOffset(0, y), BackgroundColor3 = C.accent, BackgroundTransparency = 0.25, Text = text, TextColor3 = C.text, TextSize = 24, Font = Enum.Font.GothamBold }, pad)
	round(b, 10)
	b.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then RT.Vertical = val end
	end)
	b.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			if RT.Vertical == val then RT.Vertical = 0 end -- thả nút => dừng hẳn, không tự tăng/giảm
		end
	end)
end
padBtn("▲", 0, 1)
padBtn("▼", 68, -1)
for _, f in { "FlyAir", "FlyDron", "FlyDown" } do
	State.listen(f, function() pad.Visible = F.FlyAir or F.FlyDron or F.FlyDown or false end)
end
-- Phím tắt: Space lên, LeftControl xuống
Conn.set("keysDown", UIS.InputBegan, function(i, gp)
	if gp then return end
	if i.KeyCode == Enum.KeyCode.Space then RT.Vertical = 1 elseif i.KeyCode == Enum.KeyCode.LeftControl then RT.Vertical = -1 end
end)
Conn.set("keysUp", UIS.InputEnded, function(i)
	if i.KeyCode == Enum.KeyCode.Space or i.KeyCode == Enum.KeyCode.LeftControl then RT.Vertical = 0 end
end)

-- Đồng bộ ô số với giá trị thay đổi tự động (độ cao Dron / độ sâu Down)
local refreshAcc = 0
Conn.set("uiRefresh", RunService.Heartbeat, function(dt)
	refreshAcc += dt
	if refreshAcc < 0.25 then return end
	refreshAcc = 0
	for _, fn in UI.refreshers do fn() end
end)

-- Nút X: tắt toàn bộ tính năng, khôi phục mọi thứ, ngắt mọi kết nối rồi hủy giao diện
btnClose.MouseButton1Click:Connect(function()
	for flag in pairs(F) do State.set(flag, false) end
	Esp.clearAll()
	Conn.dropAll()
	if espGui then espGui:Destroy() end
	if hlFolder then hlFolder:Destroy() end
	gui:Destroy()
end)
