local api=require("api")

local compression_map={}
for entry in ("\n 0123456789abcdefghijklmnopqrstuvwxyz!#%(){}[]<>+=/*:;.,~_"):gmatch(".") do
	table.insert(compression_map, entry)
end
local function decompress(code)
	-- decompress code
	local lua=""
	local mode=0
	local copy=nil
	local i=8
	local codelen=bit.lshift(code:byte(5, 5), 8)+code:byte(6, 6)
	log('codelen', codelen)
	while #lua<codelen do
		i=i+1
		local byte=string.byte(code, i, i)
		if byte==nil then
			error('reached end of code')
		else
			if mode==1 then
				lua=lua..code:sub(i, i)
				mode=0
			elseif mode==2 then
				-- copy from buffer
				local offset=(copy-0x3c)*16+bit.band(byte, 0xf)
				local length=bit.rshift(byte, 4)+2
					local offset=#lua-offset
				local buffer=lua:sub(offset+1, offset+length)
				lua=lua..buffer
				mode=0
			elseif byte==0x00 then
				-- output next byte
				mode=1
			elseif byte>=0x01 and byte<=0x3b then
				-- output this byte from map
				lua=lua..compression_map[byte]
			elseif byte>=0x3c then
				-- copy previous bytes
				mode=2
				copy=byte
			end
		end
	end
	return lua
end

local cart={}

function cart.load_p8(filename)
	log("Loading", filename)

	local lua=""
	pico8.quads={}
	pico8.spritesheet_data=love.image.newImageData(128, 128)
	pico8.spritesheet_data:mapPixel(function() return 0, 0, 0, 1 end)
	pico8.map={}
	for y=0, 63 do
		pico8.map[y]={}
		for x=0, 127 do
			pico8.map[y][x]=0
		end
	end
	pico8.spriteflags={}
	for i=0, 255 do
		pico8.spriteflags[i]=0
	end

	local header=love.filesystem.read(filename, 8)
	if header=="\137PNG\r\n\26\n" then
		local data=love.image.newImageData(filename)
		if data:getWidth()~=160 or data:getHeight()~=205 then
			error("Image is the wrong size")
		end

		local outX=0
		local outY=0
		local inbyte=0
		local lastbyte=nil
		local mapY=32
		local mapX=0
		local version=nil
		local compressed=false
		local sprite=0
		for y=0, 204 do
			for x=0, 159 do
				local r, g, b, a=data:getPixel(x, y)
				r, g, b, a=r*255, g*255, b*255, a*255
				-- extract lowest bits
				r=bit.band(r, 0x0003)
				g=bit.band(g, 0x0003)
				b=bit.band(b, 0x0003)
				a=bit.band(a, 0x0003)
				local byte=bit.lshift(a, 6)+bit.lshift(r, 4)+bit.lshift(g, 2)+b
				local lo=bit.band(byte, 0x0f)
				local hi=bit.rshift(byte, 4)
				if inbyte<0x2000 then
					-- spritesheet
					if outY>=64 then
						pico8.map[mapY][mapX]=byte
						mapX=mapX+1
						if mapX==128 then
							mapX=0
							mapY=mapY+1
						end
					end
					pico8.spritesheet_data:setPixel(outX, outY, lo/15, 0, 0, 1)
					outX=outX+1
					pico8.spritesheet_data:setPixel(outX, outY, hi/15, 0, 0, 1)
					outX=outX+1
					if outX==128 then
						outY=outY+1
						outX=0
						if outY==128 then
							-- end of spritesheet, generate quads
							pico8.spritesheet=love.graphics.newImage(pico8.spritesheet_data)
							local sprite=0
							for yy=0, 15 do
								for xx=0, 15 do
									pico8.quads[sprite]=love.graphics.newQuad(xx*8, yy*8, 8, 8, pico8.spritesheet:getDimensions())
									sprite=sprite+1
								end
							end
							mapY=0
							mapX=0
						end
					end
				elseif inbyte<0x3000 then
					-- map data
					pico8.map[mapY][mapX]=byte
					mapX=mapX+1
					if mapX==128 then
						mapX=0
						mapY=mapY+1
					end
				elseif inbyte<0x3100 then
					-- sprite flags
					pico8.spriteflags[sprite]=byte
					sprite=sprite+1
				elseif inbyte<0x3200 then
					-- music
					local _music=math.floor((inbyte-0x3100)/4)
					pico8.music[_music][inbyte%4]=bit.band(byte, 0x7F)
					pico8.music[_music].loop=bit.bor(bit.rshift(bit.band(byte, 0x80), 7-inbyte%4), pico8.music[_music].loop)
				elseif inbyte<0x8000 then
					-- code, possibly compressed
					if inbyte==0x4300 then
						compressed=(byte==58)
					end
					lua=lua..string.char(byte)
				elseif inbyte==0x8000 then
					version=byte
				end
				lastbyte=byte
				inbyte=inbyte+1
			end
		end

		-- decompress code
		log('version', version)
		if version>8 then
			error(string.format('unknown file version %d', version))
		end

		if compressed then
			lua=decompress(lua)
		elseif lua:find("\0", nil, true) then
			lua=lua:match("(.-)%z")
		end
	else
		local f=love.filesystem.newFile(filename, 'r')
		if not f then
			error(string.format("Unable to open: %s", filename))
		end
		local data, size=f:read()
		f:close()
		if not data then
			error("invalid cart")
		end

		pico8.export_data = data
		
		-- strip carriage returns pico-8 style
		data=data:gsub("\r.", "\n")
		-- tack on a fake header
		if data:sub(-1) ~= "\n" then
			data=data.."\n"
		end
		data=data.."__eof__\n"

		-- check for header and vesion
		local header="pico-8 cartridge // http://www.pico-8.com\nversion "
		local start=data:find("pico%-8 cartridge // http://www.pico%-8%.com\nversion ")
		if start==nil then
			error("invalid cart")
		end
		local next_line=data:find("\n", start+#header)
		local version_str=data:sub(start+#header, next_line-1)
		local version=tonumber(version_str)
		log("version", version)

		-- extract the lua
		lua=data:match("\n__lua__.-\n(.-)\n__") or ""

		-- load the sprites into an imagedata
		-- generate a quad for each sprite index
		local gfxdata=data:match("\n__gfx__.-\n(.-\n)\n-__")

		pico8.gfx_data = gfxdata

		if gfxdata then
			local row=0

			for line in gfxdata:gmatch("(.-)\n") do
				local col=0
				for v in line:gmatch(".") do
					v=tonumber(v, 16)
					pico8.spritesheet_data:setPixel(col, row, v/15, 0, 0, 1)

					col=col+1
					if col==128 then break end
				end
				row=row+1
				if row==128 then break end
			end
		end

		local shared=0

		if version>3 then
			local tx, ty=0, 32
			for sy=64, 127 do
				for sx=0, 127, 2 do
					-- get the two pixel values and merge them
					local lo=pico8.spritesheet_data:getPixel(sx, sy)*15
					local hi=pico8.spritesheet_data:getPixel(sx+1, sy)*15
					local v=bit.bor(bit.lshift(hi, 4), lo)
					pico8.map[ty][tx]=v
					shared=shared+1
					tx=tx+1
					if tx==128 then
						tx=0
						ty=ty+1
					end
				end
			end
		end

		for y=0, 15 do
			for x=0, 15 do
				pico8.quads[y*16+x]=love.graphics.newQuad(8*x, 8*y, 8, 8, 128, 128)
			end
		end

		pico8.spritesheet=love.graphics.newImage(pico8.spritesheet_data)

		-- load the sprite flags
		local gffdata=data:match("\n__gff__.-\n(.-\n)\n-__")
		--cart.export_data = --cart.export_data .. gffdata .. "\n"

		if gffdata then
			local sprite=0
			local gffpat=(version<=2 and "." or "..")

			for line in gffdata:gmatch("(.-)\n") do
				local col=0

				for v in line:gmatch(gffpat) do
					v=tonumber(v, 16)
					pico8.spriteflags[sprite+col]=v
					col=col+1
					if col==128 then break end
				end

				sprite=sprite+128
				if sprite==256 then break end
			end
		end

		-- convert the tile data to a table
		local mapdata=data:match("\n__map__.-\n(.-\n)\n-__")
		--cart.export_data = --cart.export_data .. mapdata .. "\n"

		if mapdata then
			local row=0
			local tiles=0

			for line in mapdata:gmatch("(.-)\n") do
				local col=0
				for v in line:gmatch("..") do
					v=tonumber(v, 16)
					pico8.map[row][col]=v
					col=col+1
					tiles=tiles+1
					if col==128 then break end
				end
				row=row+1
				if row==32 then break end
			end
		end
	end

	-- patch the lua
	lua=lua:gsub("!=", "~=").."\n"
	-- rewrite shorthand if statements eg. if (not b) i=1 j=2
	lua=lua:gsub("if%s*(%b())%s*([^\n]*)\n", function(a, b)
		local nl=a:find('\n', nil, true)
		local th=b:find('%f[%w]then%f[%W]')
		local an=b:find('%f[%w]and%f[%W]')
		local o=b:find('%f[%w]or%f[%W]')
		local ce=b:find('--', nil, true)
		if not (nl or th or an or o) then
			if ce then
				local c, t=b:match("(.-)(%s-%-%-.*)")
				return "if "..a:sub(2, -2).." then "..c.." end"..t.."\n"
			else
				return "if "..a:sub(2, -2).." then "..b.." end\n"
			end
		end
	end)
	-- rewrite assignment operators
	lua=lua:gsub("(%S+)%s*([%+-%*/%%])=", "%1 = %1 %2 ")
	-- convert binary literals to hex literals
	lua=lua:gsub("([^%w_])0[bB]([01.]+)", function(a, b)
		local p1, p2=b, ""
		if b:find('.', nil, true) then
			p1, p2=b:match("(.-)%.(.*)")
		end
		-- pad to 4 characters
		p2=p2..string.rep("0", 3-((#p2-1)%4))
		p1, p2=tonumber(p1, 2), tonumber(p2, 2)
		if p1 and p2 then
			return string.format("%s0x%x.%x", a, p1, p2)
		end
	end)

	-- injecting room restart on clear and reset fruit
	lua = lua .. "\nfunction next_room()load_room(room.x,room.y)end\nload_room_o=load_room\nfunction load_room()load_room_o()got_fruit[level_index()+1]=false\nend\n"

	-- INJECTING AUTOTILE CAPABILITIES
	lua = "\nfunction sld(x,y)\nlocal rx = room.x*16\nlocal ry = room.y*16\nif x > rx+15 or x < rx or y > ry+15 or y < ry then\nreturn true\nend\nlocal n = mget(x,y)\nfor _, e in pairs(tiles) do\nif e == n then\nreturn true\nend\nend\nreturn false\nend\ntiles = {32,55,54,51,52,49,53,50,39,48,35,38,33,36,34,37,72}\nfunction update_autotile()\nlocal rx = room.x*16\nlocal ry = room.y*16\nfor x=0,15 do\nfor y=0,15 do\nlocal count = 0\nif sld(rx+x, ry+y) then\nif sld(rx+x, ry+y-1) then\ncount = count + 1\nend\nif sld(rx+x-1, ry+y) then\ncount = count + 2\nend\nif sld(rx+x+1, ry+y) then\ncount = count + 4\nend\nif sld(rx+x, ry+y+1) then\ncount = count + 8\nend\nmset(rx+x, ry+y, tiles[count+1])\nend\nend\nend\nend\n" .. lua

	local cart_env={}
	for k, v in pairs(api) do
		cart_env[k]=v
	end
	cart_env._ENV=cart_env -- Lua 5.2 compatibility hack

	local ok, f, e=pcall(load, lua, "@"..filename)
	if not ok or f==nil then
		local ln=1
		lua="1:"..lua:gsub("\n", function(a) ln=ln+1 return "\n"..ln..":" end)
		log('=======8<========')
		log(lua)
		log('=======>8========')
		error("Error loading lua: "..tostring(e),0)
	else
		local result
		setfenv(f, cart_env)
		love.graphics.setShader(pico8.draw_shader)
		love.graphics.setCanvas(pico8.screen)
		love.graphics.origin()
		restore_clip()
		ok, result=pcall(f)
		if not ok then
			error("Error running lua: "..tostring(result))
		else
			log("lua completed")
		end
	end
	log("finished loading cart", filename)

	return cart_env
end

return cart
