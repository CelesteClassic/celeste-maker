pico8={
	fps=30,
	frames=0,
	pal_transparent={},
	resolution={128, 128},
	palette={
		{0,  0,  0,  255},
		{29, 43, 83, 255},
		{126,37, 83, 255},
		{0,  135,81, 255},
		{171,82, 54, 255},
		{95, 87, 79, 255},
		{194,195,199,255},
		{255,241,232,255},
		{255,0,  77, 255},
		{255,163,0,  255},
		{255,240,36, 255},
		{0,  231,86, 255},
		{41, 173,255,255},
		{131,118,156,255},
		{255,119,168,255},
		{255,204,170,255}
	},
	spriteflags={},
	audio_channels={},
	sfx={},
	usermemory={},
	cartdata={},
	clipboard="",
	keypressed={
		[0]={},
		[1]={},
		counter=0
	},
	kbdbuffer={},
	keymap={
		[0]={
			[0]={'left'},
			[1]={'right'},
			[2]={'up'},
			[3]={'down'},
			[4]={'z', 'c', 'n', 'kp-'},
			[5]={'x', 'v', 'm', '8'},
		},
		[1]={
			[0]={'s'},
			[1]={'f'},
			[2]={'e'},
			[3]={'d'},
			[4]={'tab', 'lshift'},
			[5]={'q', 'a'},
		}
	},
	mwheel=0,
	cursor={0, 0},
	camera_x=0,
	camera_y=0,
	draw_palette={},
	display_palette={},
	pal_transparent={},
}

require("strict")
local bit=require("bit")

local flr, abs=math.floor, math.abs

local frametime=1/pico8.fps
local cart=nil
local cartname=nil
local love_args=nil
local scale=nil
local xpadding=nil
local ypadding=nil
local tobase=nil
local topad=nil
local gif_recording=nil
local gif_canvas=nil
local osc
local host_time=0
local retro_mode=false
local mobile=false
local api, cart, gif

local __buffer_count=8
local __buffer_size=1024
local __sample_rate=22050
local channels=1
local bits=16

local autotile=false

log=print
--log=function() end

function shdr_unpack(thing)
	return unpack(thing, 0, 15)
end

local function get_bits(v, s, e)
	local mask=bit.lshift(bit.lshift(1, s)-1, e)
	return bit.rshift(bit.band(mask, v))
end

function restore_clip()
	if pico8.clip then
		love.graphics.setScissor(unpack(pico8.clip))
	else
		love.graphics.setScissor()
	end
end

function setColor(c)
	love.graphics.setColor(c/15, 0, 0, 1)
end

local exts={"", ".p8", ".p8.png", ".png"}
function _load(filename)
	filename=filename or cartname
	for i=1, #exts do
		if love.filesystem.getInfo(filename..exts[i]) ~= nil then
			filename=filename..exts[i]
			break
		end
	end
	cartname=filename

	pico8.camera_x=0
	pico8.camera_y=0
	love.graphics.origin()
	pico8.clip=nil
	love.graphics.setScissor()
	api.pal()
	pico8.color=6
	setColor(pico8.color)
	love.graphics.setCanvas(pico8.screen)
	love.graphics.setShader(pico8.draw_shader)

	pico8.cart=cart.load_p8(filename)
	for i=0, 0x1c00-1 do
		pico8.usermemory[i]=0
	end
	for i=0, 63 do
		pico8.cartdata[i]=0
	end
	if pico8.cart._init then pico8.cart._init() end
	if pico8.cart._update60 then
		setfps(60)
	else
		setfps(30)
	end

end

function love.resize(w, h)
	love.graphics.clear()
	-- adjust stuff to fit the screen
	scale=math.max(math.min(w/pico8.resolution[1], h/(pico8.resolution[2]*1.5+10)), 1)
	if not mobile then
		scale=math.floor(scale)
	end
	xpadding=(w-pico8.resolution[1]*scale)/2
	ypadding=10
	tobase=math.min(w, h)/9
	topad=tobase/8
end

local function note_to_hz(note)
	return 440*2^((note-33)/12)
end

function love.load(argv)
	love_args=argv
	mobile=(love.system.getOS()=="Android" or love.system.getOS()=="iOS")

	love.resize(love.graphics.getDimensions()) -- Setup initial scaling and padding

	osc={}
	-- tri
	osc[0]=function(x)
		local t=x%1
		return (abs(t*2-1)*2-1)*0.5
	end
	-- uneven tri
	osc[1]=function(x)
		local t=x%1
		return (((t<0.875) and (t*16/7) or ((1-t)*16))-1)*0.5
	end
	-- saw
	osc[2]=function(x)
		return (x%1-0.5)*2/3
	end
	-- sqr
	osc[3]=function(x)
		return (x%1<0.5 and 1 or-1)*0.25
	end
	-- pulse
	osc[4]=function(x)
		return (x%1<0.3125 and 1 or-1)*0.25
	end
	-- organ
	osc[5]=function(x)
		x=x*4
		return (abs((x%2)-1)-0.5+(abs(((x*0.5)%2)-1)-0.5)/2-0.1)*0.5
	end
	osc[6]=function()
		local lastx=0
		local sample=0
		local update=false
		local hz48=note_to_hz(48)
		return function(x)
			local hz=((x-lastx)%1)*__sample_rate
			lastx=x
			local scale=hz*(131072/343042875)+(16/889)

			update=not update
			if update then
				sample=sample+scale*(love.math.random()*2-1)
			end
			local output=sample*(45/32)
			if hz > hz48 then
				output=output*(1.1659377442658412e+000-2.3350687035974510e-004*hz+8.3385655344351036e-008*hz^2-1.1509506025078735e-011*hz^3) -- approximate
			end
			sample=math.max(math.min(sample, (6143/31115)), -(6143/31115))
			return output
		end
	end
	-- detuned tri
	osc[7]=function(x)
		x=x*2
		return (abs(((x*127/128)%2)-1)/2+abs((x%2)-1)-1)*2/3
	end
	-- saw from 0 to 1, used for arppregiator
	osc["saw_lfo"]=function(x)
		return x%1
	end

	pico8.audio_source=love.audio.newQueueableSource(__sample_rate, bits, channels, __buffer_count)
	pico8.audio_source:play()
	pico8.audio_buffer=love.sound.newSoundData(__buffer_size, __sample_rate, bits, channels)

	for i=0, 3 do
		pico8.audio_channels[i]={
			oscpos=0,
			sample=0,
			noise=osc[6](),
		}
	end

	love.graphics.clear()
	love.graphics.setDefaultFilter('nearest', 'nearest')
	pico8.screen=love.graphics.newCanvas(pico8.resolution[1], pico8.resolution[2])
	pico8.tmpscr=love.graphics.newCanvas(pico8.resolution[1], pico8.resolution[2])

	local glyphs=""
	for i=32, 127 do
		glyphs=glyphs..string.char(i)
	end
	for i=128, 153 do
		glyphs=glyphs..string.char(194, i)
	end
	local font=love.graphics.newImageFont("font.png", glyphs, 1)
	love.graphics.setFont(font)
	font:setFilter('nearest', 'nearest')

	--love.mouse.setVisible(false)
	love.graphics.setLineStyle('rough')
	love.graphics.setPointSize(1)
	love.graphics.setLineWidth(1)

	for i=0, 15 do
		pico8.draw_palette[i]=i
		pico8.pal_transparent[i]=i==0 and 0 or 1
		pico8.display_palette[i]=pico8.palette[i+1]
	end

	local name, version, vendor, device=love.graphics.getRendererInfo()
	local pishaderfix
	if name=="OpenGL ES" and not version:find(" Mesa ", nil, true) and vendor=="Broadcom" then
		print("Using proprietary Broadcom video driver shader fixes")
		pishaderfix=function(code)
			return (code:gsub("ifblock(%b());", function(name)
				name=name:sub(2, -2)
				local kind, length=code:match("extern ([%a_][%w_]-) "..name.."%[(%d-)%]")
				local code=kind.." _"..name..";"
				for i=0, length-1 do
					code=code.."\n\t"..(i==0 and "" or "else ").."if (index=="..i..")\n\t\t_"..name.."="..name.."["..i.."];"
				end
				return code
			end):gsub("([%a_][%w_]-)%[index%]", "_%1"))
		end
	else
		pishaderfix=function(code)
			return (code:gsub("ifblock%b();", ""))
		end
	end

	pico8.draw_shader=love.graphics.newShader(pishaderfix([[
extern float palette[16];

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
	int index=int(color.r*15.0+0.5);
	ifblock(palette);
	return vec4(palette[index]/15.0, 0.0, 0.0, 1.0);
}]]))
	pico8.draw_shader:send('palette', shdr_unpack(pico8.draw_palette))

	pico8.sprite_shader=love.graphics.newShader(pishaderfix([[
extern float palette[16];
extern float transparent[16];

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
	int index=int(Texel(texture, texture_coords).r*15.0+0.5);
	ifblock(palette);
	ifblock(transparent);
	return vec4(palette[index]/15.0, 0.0, 0.0, transparent[index]);
}]]))
	pico8.sprite_shader:send('palette', shdr_unpack(pico8.draw_palette))
	pico8.sprite_shader:send('transparent', shdr_unpack(pico8.pal_transparent))

	pico8.text_shader=love.graphics.newShader(pishaderfix([[
extern float palette[16];

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
	vec4 texcolor=Texel(texture, texture_coords);
	int index=int(color.r*15.0+0.5);
	ifblock(palette);
	return vec4(palette[index]/15.0, 0.0, 0.0, texcolor.a);
}]]))
	pico8.text_shader:send('palette', shdr_unpack(pico8.draw_palette))

	pico8.display_shader=love.graphics.newShader(pishaderfix([[
extern vec4 palette[16];

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
	int index=int(Texel(texture, texture_coords).r*15.0+0.5);
	ifblock(palette);
	// lookup the colour in the palette by index
	return palette[index]/255.0;
}]]))
	pico8.display_shader:send('palette', shdr_unpack(pico8.display_palette))

	api=require("api")
	cart=require("cart")
	gif=require("gif")

	-- load the cart
	_load('celeste.p8')
end

local function inside(x, y, x0, y0, w, h)
	return (x>=x0 and x<x0+w and y>=y0 and y<y0+h)
end

local function touchcheck(i, x, y)
	local screen_w, screen_h=love.graphics.getDimensions()
	local ytop=screen_h-tobase*4-topad*2
	local length=tobase*3+topad*2

	if i==0 then
		return inside(x, y, topad, ytop, tobase, length)
	elseif i==1 then
		return inside(x, y, tobase*2+topad*3, ytop, tobase, length)
	elseif i==2 then
		return inside(x, y, topad, ytop, length, tobase)
	elseif i==3 then
		return inside(x, y, topad, screen_h-tobase*2, length, tobase)
	elseif i==4 then
		return (screen_w-tobase*8/3-x)^2+(screen_h-tobase*3/2-y)^2<=(tobase/4*3)^2
	elseif i==5 then
		return (screen_w-tobase-x)^2+(screen_h-tobase*2-y)^2<=(tobase/4*3)^2
	end
end

local function update_buttons()
	local init, loop=pico8.fps/2, pico8.fps/7.5
	local touches
	if mobile then
		touches=love.touch.getTouches()
	end
	for p=0, 1 do
		local keymap=pico8.keymap[p]
		local keypressed=pico8.keypressed[p]
		for i=0, 5 do
			local btn=false
			for _, testkey in pairs(keymap[i]) do
				if love.keyboard.isDown(testkey) then
					btn=true
					break
				end
			end
			if not btn and mobile and p==0 then
				for _, id in pairs(touches) do
					btn=touchcheck(i, love.touch.getPosition(id))
					if btn then break end
				end
			end
			if not btn then
				keypressed[i]=false
			elseif not keypressed[i] then
				pico8.keypressed.counter=init
				keypressed[i]=true
			end
		end
	end
	pico8.keypressed.counter=pico8.keypressed.counter-1
	if pico8.keypressed.counter<=0 then
		pico8.keypressed.counter=loop
	end
end

function love.update(dt)
	pico8.frames=pico8.frames+1
	update_buttons()
	if pico8.cart._update60 then
		pico8.cart._update60()
	elseif pico8.cart._update then
		pico8.cart._update()
	end
end

function love.draw()
	-- run the cart's draw function
	if pico8.cart._draw then pico8.cart._draw() end
end

function restore_camera()
	love.graphics.origin()
	love.graphics.translate(-pico8.camera_x, -pico8.camera_y)
end

selected = 0
isEditMode = false
isEditMode_last = false
function flip_screen()
	if pico8.cart.is_title() then
		api.print("maker", 55, 55, 6)
		api.print("'p' to switch modes", 28, 88, 5)	
	end

	love.graphics.setShader(pico8.display_shader)
	love.graphics.setCanvas()
	love.graphics.origin()
	love.graphics.setScissor()

	if not isEditMode and isEditMode_last then
		pico8.cart.load_room(pico8.cart.room.x, pico8.cart.room.y)
	else
		love.graphics.clear()
		love.graphics.draw(pico8.screen, xpadding, ypadding, 0, scale, scale)
	end


	isEditMode_last = false
	if isEditMode then

		love.graphics.setShader(pico8.display_shader)
		love.graphics.setCanvas(pico8.screen)
		api.cls()
		api.map(pico8.cart.room.x * 16, pico8.cart.room.y * 16,0,0,16,16)

		love.graphics.setCanvas()
		love.graphics.setShader(pico8.display_shader)
		love.graphics.draw(pico8.screen, xpadding, ypadding, 0, scale, scale)

		local mx = love.mouse.getX()
		local my = love.mouse.getY()
		
		local ww = love.graphics.getWidth()
		local wh = love.graphics.getHeight()
		local startx = xpadding
		local finishx = xpadding + scale*128
		local starty = ypadding
		local finishy = ypadding + scale*128
		local sp_starty = finishy + 10

		for spr = 1, #pico8.quads/2 do
			love.graphics.draw(pico8.spritesheet, pico8.quads[spr], startx+spr%16*8*scale, sp_starty+math.floor(spr/16)*8*scale, 0, scale)
		end
		love.graphics.setShader()

		-- draw grid
		love.graphics.setColor(0, 0, 0, .2)
		for i=1,15 do
			love.graphics.line(startx+i*8*scale, starty, startx+i*8*scale, finishy)
			love.graphics.line(startx, starty+i*8*scale, finishx, starty+i*8*scale)
		end

		-- draw white outline around selected map tile
		love.graphics.setColor(1, 1, 1)
		if mx > startx and mx < finishx and
		my > starty and my < finishy then
			love.graphics.rectangle("line", startx + flr((mx-startx) / (scale*8)) * scale*8, starty + flr((my-starty) / (scale*8)) * scale*8, 8*scale, 8*scale)
		end
		
		-- draw white outline around selected spritesheet tile
		love.graphics.rectangle("line", startx + selected%16*8*scale, sp_starty + math.floor(selected/16)*8*scale, 8*scale, 8*scale)

		-- mouse handling
		local m_primary = love.mouse.isDown(1)
		local m_secondary = love.mouse.isDown(2)
		local m_middle = love.mouse.isDown(3)
		if mx > startx and mx < finishx
		and my > starty and my < finishy then
			local tx = flr((mx-startx) / (8*scale)) + pico8.cart.room.x*16
			local ty = flr((my-starty) / (8*scale)) + pico8.cart.room.y*16

			if m_primary or m_secondary then
				pico8.map[ty][tx] = m_secondary and 0 or selected
				if autotile then
					pico8.cart.update_autotile()
				end
			elseif m_middle then
				selected = pico8.map[ty][tx]
			end
		elseif mx > startx and mx < finishx
		and my > sp_starty and my < sp_starty+scale*8*8
		and m_primary then
			local tx = flr((mx-startx) / (8*scale))
			local ty = flr((my-sp_starty) / (8*scale))
			local q = tx%16+ty*16

			if q < #pico8.quads/2 then
				selected = q
			end
		end

		isEditMode_last = true
	end
	-------------------------------------------------------------------------------------------------------------------

	love.graphics.present()

	-- get ready for next time
	love.graphics.setShader(pico8.draw_shader)
	love.graphics.setCanvas(pico8.screen)
	restore_clip()
	restore_camera()
end

local function lowpass(y0, y1, cutoff)
	local RC=1.0/(cutoff*2*3.14)
	local dt=1.0/__sample_rate
	local alpha=dt/(RC+dt)
	return y0+(alpha*(y1-y0))
end

local note_map={[0]='C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-'}

local function note_to_string(note)
	local octave=flr(note/12)
	local note=flr(note%12)
	return string.format("%s%d", note_map[note], octave)
end

local function oldosc(osc)
	local x=0
	return function(freq)
		x=x+freq/__sample_rate
		return osc(x)
	end
end

local function lerp(a, b, t)
	return (b-a)*t+a
end

local function isCtrlOrGuiDown()
	return (love.keyboard.isDown('lctrl') or love.keyboard.isDown('lgui') or love.keyboard.isDown('rctrl') or love.keyboard.isDown('rgui'))
end

local function indexOf(t, object)
    for i=1,#t do
        if object == t[i] then
            return i
        end
    end
end

function love.keypressed(key)
	if cart and pico8.cart._keydown then
		return pico8.cart._keydown(key)
	end
	if key=='a' and isCtrlOrGuiDown() then
		autotile = not autotile
	elseif key=='s' and isCtrlOrGuiDown() then
		local map_string = ""
		local gfx_string = ""

		-- gfx data (gfx half)
		for i=0,128*64-1 do
			if i%128==0 and i>0 then
				gfx_string = gfx_string .. "\n"
			end

			local cint = pico8.spritesheet_data:getPixel(i%128, flr(i/128)) * 15

			gfx_string = gfx_string .. string.format("%x", cint)
		end
		
		-- gfx data (map half)
		for i=0,128*32-1 do
			if i%64==0 then
				gfx_string = gfx_string .. "\n"
			end
			local tile = api.mget(i%128, 32+flr(i/128))
			local hex = string.format("%x", tile)
			if #hex==1 then
				hex = "0" .. hex
			end
			local reverse = ""
			reverse = reverse .. string.sub(hex,2,2)
			reverse = reverse .. string.sub(hex,1,1)
			gfx_string = gfx_string .. reverse
		end

		-- map data
		for i=0,128*32-1 do
			if i%128==0 and i>0 then
				map_string = map_string .. "\n"
			end
			local tile = api.mget(i%128, flr(i/128))
			local hex = string.format("%x", tile)
			
			if #hex==1 then
				hex = "0" .. hex
			end
			map_string = map_string .. hex
		end

		local export_data=pico8.export_data
		export_data=export_data:gsub("__map__[%dabcdef%c]+","__map__\n"..map_string.."\n")
		export_data=export_data:gsub("__gfx__[%dabcdef%c]+","__gfx__\n"..gfx_string.."\n")
		local file=love.filesystem.newFile(cartname)
		file:open("w")
		file:write(export_data)
	elseif ((key=='right' and isEditMode) or key=='f') and pico8.cart.level_index()~=30 and not pico8.cart.is_title() then -- use level_index_max rather than 30 once implemented
		local target = pico8.cart.level_index()+1
		pico8.cart.load_room(target%8, flr(target/8))
	elseif ((key=='left' and isEditMode) or key=='s') and pico8.cart.level_index()~=0 and not pico8.cart.is_title() then
		local target = pico8.cart.level_index()-1
		pico8.cart.load_room(target%8, flr(target/8))
	elseif key=='p' and not pico8.cart.is_title() then
		isEditMode = not isEditMode
	elseif key=='r' and isCtrlOrGuiDown() and love.keyboard.isDown('lshift') then
		_load()
	elseif key=='r' and isCtrlOrGuiDown() then
		pico8.cart.restart_room()
	elseif key=='q' and isCtrlOrGuiDown() then
		love.event.quit()
	elseif key=='v' and isCtrlOrGuiDown() then
		pico8.clipboard=love.system.getClipboardText()
	elseif key=='f1' or key=='f6' then
		-- screenshot
		local filename=cartname..'-'..os.time()..'.png'
		love.graphics.captureScreenshot(filename)
		log('saved screenshot to', filename)
	elseif key=='f3' or key=='f8' then
		-- start recording
		if gif_recording==nil then
			local err
			gif_recording, err=gif.new(cartname..'-'..os.time()..'.gif')
			if not gif_recording then
				log('failed to start recording: '..err)
			else
				gif_canvas=love.graphics.newCanvas(pico8.resolution[1]*2, pico8.resolution[2]*2)
				log('starting record ...')
			end
		else
			log('recording already in progress')
		end
	elseif key=='f4' or key=='f9' then
		-- stop recording and save
		if gif_recording~=nil then
			gif_recording:close()
			log('saved recording to '..gif_recording.filename)
			gif_recording=nil
			gif_canvas=nil
		else
			log('no active recording')
		end
	end
end

function love.keyreleased(key)
	if cart and pico8.cart._keyup then
		return pico8.cart._keyup(key)
	end
end

function love.textinput(text)
	table.insert(pico8.kbdbuffer, text)
	while #pico8.kbdbuffer > 255 do
		table.remove(pico8.kbdbuffer, 1)
	end
	if cart and pico8.cart._textinput then return pico8.cart._textinput(text) end
end

function love.wheelmoved(x, y)
	pico8.mwheel=pico8.mwheel+y
end

function love.graphics.point(x, y)
	love.graphics.rectangle('fill', x, y, 1, 1)
end

function setfps(fps)
	pico8.fps=flr(fps)
	if pico8.fps<=0 then
		pico8.fps=30
	end
	frametime=1/pico8.fps
end

function getMouseX()
	return math.floor((love.mouse.getX()-xpadding)/scale)
end

function getMouseY()
	return math.floor((love.mouse.getY()-ypadding)/scale)
end

function love.run()
	if love.math then
		love.math.setRandomSeed(os.time())
		for i=1, 3 do love.math.random() end
	end
	math.randomseed(os.time())
	for i=1, 3 do math.random() end

	if love.load then love.load(love.arg.parseGameArguments(arg), arg) end

	-- We don't want the first frame's dt to include time taken by love.load.
	if love.timer then love.timer.step() end

	local dt=0

	-- Main loop time.
	return function()
		-- Process events.
		if love.event then
			love.graphics.setCanvas() -- TODO: Rework this
			love.event.pump()
			love.graphics.setCanvas(pico8.screen) -- TODO: Rework this
			for name, a, b, c, d, e, f in love.event.poll() do
				if name == "quit" then
					if not love.quit or not love.quit() then
						return a or 0
					end
				end
				love.handlers[name](a, b, c, d, e, f)
			end
		end

		-- Update dt, as we'll be passing it to update
		if love.timer then dt=dt+love.timer.step() end

		-- Call update and draw
		local render=false
		while dt>frametime do
			host_time=host_time+dt
			if love.update and not isEditMode then love.update(frametime) end -- will pass 0 if love.timer is disabled
			dt=dt-frametime
			render=true
		end

		if render and love.graphics and love.graphics.isActive() then
			love.graphics.origin()
			if love.draw then love.draw() end
			-- draw the contents of pico screen to our screen
			flip_screen()
			-- reset mouse wheel
			pico8.mwheel=0
		end

		if love.timer then love.timer.sleep(0.001) end
	end
end
