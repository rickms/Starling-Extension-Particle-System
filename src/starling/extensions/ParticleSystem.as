// =================================================================================================
//
//	Starling Framework - Particle System Extension
//	Copyright 2012 Gamua OG. All Rights Reserved.
//
//	This program is free software. You can redistribute and/or modify it
//	in accordance with the terms of the accompanying license agreement.
//
// =================================================================================================

package starling.extensions
{
    import com.adobe.utils.AGALMiniAssembler;
    
    import flash.display3D.Context3D;
    import flash.display3D.Context3DBlendFactor;
    import flash.display3D.Context3DProgramType;
    import flash.display3D.Context3DTextureFormat;
    import flash.display3D.Context3DVertexBufferFormat;
    import flash.display3D.IndexBuffer3D;
    import flash.display3D.Program3D;
    import flash.display3D.VertexBuffer3D;
    import flash.geom.Matrix;
    import flash.geom.Point;
    import flash.geom.Rectangle;
    import flash.utils.ByteArray;
    import flash.utils.Endian;
    
    import starling.animation.IAnimatable;
    import starling.core.RenderSupport;
    import starling.core.Starling;
    import starling.display.DisplayObject;
    import starling.errors.MissingContextError;
    import starling.events.Event;
    import starling.textures.Texture;
    import starling.utils.MatrixUtil;
    import starling.utils.VertexData;
    
    /** Dispatched when emission of particles is finished. */
    [Event(name="complete", type="starling.events.Event")]
    
    public class ParticleSystem extends DisplayObject implements IAnimatable
    {

        /** The number of bytes per element. Positions and texture coordinates take up one
         *  element per component; color data is stored in a single element. */
        public static const BYTES_PER_ELEMENT:int = 4;
        
        /** The total number of elements stored per vertex (in units of 32 bits).  */
        public static const ELEMENTS_PER_VERTEX:int = 5;
        
        /** The offset of position data (x, y) within a vertex (in units of 32 bits). */
        public static const POSITION_OFFSET:int = 0;
        
        /** The offset of color data (one RGBA uint) within a vertex (in units of 32 bits). */
        public static const COLOR_OFFSET:int = 2;
        
        /** The offset of texture coordinates (u, v) within a vertex (in units of 32 bits). */
        public static const TEXCOORD_OFFSET:int = 3;
        
        private static const BYTES_PER_VERTEX:int         = ELEMENTS_PER_VERTEX * BYTES_PER_ELEMENT;
        private static const POSITION_OFFSET_IN_BYTES:int = POSITION_OFFSET     * BYTES_PER_ELEMENT;
        private static const COLOR_OFFSET_IN_BYTES:int    = COLOR_OFFSET        * BYTES_PER_ELEMENT;
        private static const TEXCOORD_OFFSET_IN_BYTES:int = TEXCOORD_OFFSET     * BYTES_PER_ELEMENT;
        
        private static const MIN_ALPHA_PMA:Number = 5.0 / 255.0;

		
        private var mTexture:Texture;
        private var mParticles:Vector.<Particle>;
        private var mFrameTime:Number;
        
        private var mProgram:Program3D;
		private var mRawVertexData:ByteArray;
        private var mVertexBuffer:VertexBuffer3D;
        private var mIndices:ByteArray;
        private var mIndexBuffer:IndexBuffer3D;
        
        private var mNumParticles:int;
        private var mMaxCapacity:int;
        private var mEmissionRate:Number; // emitted particles per second
        private var mEmissionTime:Number;
        
        /** Helper objects. */
        private static var sHelperMatrix:Matrix = new Matrix();
        private static var sHelperPoint:Point = new Point();
        private static var sRenderAlpha:Vector.<Number> = new <Number>[1.0, 1.0, 1.0, 1.0];
        
        protected var mEmitterX:Number;
        protected var mEmitterY:Number;
        protected var mPremultipliedAlpha:Boolean;
        protected var mBlendFactorSource:String;     
        protected var mBlendFactorDestination:String;
        private var mBaseVertexData:VertexData;
        private var mBaseRawVertexData:ByteArray;
        
        public function ParticleSystem(texture:Texture, emissionRate:Number, 
                                       initialCapacity:int=128, maxCapacity:int=8192,
                                       blendFactorSource:String=null, blendFactorDest:String=null)
        {
            if (texture == null) throw new ArgumentError("texture must not be null");
            
            mTexture = texture;
            mPremultipliedAlpha = texture.premultipliedAlpha;
            mParticles = new Vector.<Particle>(0, false);
            mRawVertexData = new ByteArray();
            mRawVertexData.endian = Endian.LITTLE_ENDIAN;
			
            mIndices = new ByteArray();
            mIndices.endian = Endian.LITTLE_ENDIAN;
            mEmissionRate = emissionRate;
            mEmissionTime = 0.0;
            mFrameTime = 0.0;
            mEmitterX = mEmitterY = 0;
            mMaxCapacity = Math.min(8192, maxCapacity);
            
            mBlendFactorDestination = blendFactorDest || Context3DBlendFactor.ONE_MINUS_SOURCE_ALPHA;
            mBlendFactorSource = blendFactorSource ||
                (mPremultipliedAlpha ? Context3DBlendFactor.ONE : Context3DBlendFactor.SOURCE_ALPHA);
            
            
            mBaseVertexData = new VertexData(4);
            mBaseVertexData.setTexCoords(0, 0.0, 0.0);
            mBaseVertexData.setTexCoords(1, 1.0, 0.0);
            mBaseVertexData.setTexCoords(2, 0.0, 1.0);
            mBaseVertexData.setTexCoords(3, 1.0, 1.0);
            
            mBaseRawVertexData = new ByteArray();
            mBaseRawVertexData.endian = Endian.LITTLE_ENDIAN;
            mBaseRawVertexData[11] = 0xff;
            mBaseRawVertexData[31] = 0xff;
            mBaseRawVertexData[51] = 0xff;
            mBaseRawVertexData[71] = 0xff;
            
            mBaseRawVertexData.position = (20 * 1) + 12;
            mBaseRawVertexData.writeFloat(1.0);
            mBaseRawVertexData.position = (20 * 2) + 16;
            mBaseRawVertexData.writeFloat(1.0);
            mBaseRawVertexData.position = (20 * 3) + 12;
            mBaseRawVertexData.writeFloat(1.0);
            mBaseRawVertexData.writeFloat(1.0);

            createProgram();
            raiseCapacity(initialCapacity);
            
            // handle a lost device context
            Starling.current.stage3D.addEventListener(Event.CONTEXT3D_CREATE, 
                onContextCreated, false, 0, true);
        }
        
        public override function dispose():void
        {
            Starling.current.stage3D.removeEventListener(Event.CONTEXT3D_CREATE, onContextCreated);
            
            if (mVertexBuffer) mVertexBuffer.dispose();
            if (mIndexBuffer)  mIndexBuffer.dispose();
            
            super.dispose();
        }
        
        private function onContextCreated(event:Object):void
        {
            createProgram();
            raiseCapacity(0);
        }
        
        protected function createParticle():Particle
        {
            return new Particle();
        }
        
        protected function initParticle(particle:Particle):void
        {
            particle.x = mEmitterX;
            particle.y = mEmitterY;
            particle.currentTime = 0;
            particle.totalTime = 1;
            particle.color = Math.random() * 0xffffff;
        }

        protected function advanceParticle(particle:Particle, passedTime:Number):void
        {
            particle.y += passedTime * 250;
            particle.alpha = 1.0 - particle.currentTime / particle.totalTime;
            particle.scale = 1.0 - particle.alpha; 
            particle.currentTime += passedTime;
        }
        
        private function raiseCapacity(byAmount:int):void
        {
            var oldCapacity:int = capacity;
            var newCapacity:int = Math.min(mMaxCapacity, capacity + byAmount);
            var context:Context3D = Starling.context;
            
            if (context == null) throw new MissingContextError();

            mTexture.adjustVertexData(mBaseVertexData, 0, 4);			
            mParticles.fixed = false;
            
            mRawVertexData.length = newCapacity * BYTES_PER_VERTEX * 4;
            mRawVertexData.position = oldCapacity * BYTES_PER_VERTEX * 4;
            
            for (var i:int=oldCapacity; i<newCapacity; ++i)  
            {
                var numVertices:int = i * 4;
                var numIndices:int  = i * 6;
                
                mParticles[i] = createParticle();
                
                mRawVertexData.writeBytes(mBaseRawVertexData);
                
                mIndices.writeShort(numVertices);
                mIndices.writeShort(numVertices + 1);
                mIndices.writeShort(numVertices + 2);
                mIndices.writeShort(numVertices + 1);
                mIndices.writeShort(numVertices + 3);
                mIndices.writeShort(numVertices + 2);
            }
            
            mParticles.fixed = true;
           // mIndices.fixed = true;
            
            // upload data to vertex and index buffers
            
            if (mVertexBuffer) mVertexBuffer.dispose();
            if (mIndexBuffer)  mIndexBuffer.dispose();
            
            mVertexBuffer = context.createVertexBuffer(newCapacity * 4, VertexData.ELEMENTS_PER_VERTEX);
            mVertexBuffer.uploadFromByteArray(mRawVertexData, 0 , 0, newCapacity * 4);
            
            mIndexBuffer  = context.createIndexBuffer(newCapacity * 6);
            mIndexBuffer.uploadFromByteArray(mIndices,0,  0, newCapacity * 6);
        }
        
        /** Starts the emitter for a certain time. @default infinite time */
        public function start(duration:Number=Number.MAX_VALUE):void
        {
            if (mEmissionRate != 0)                
                mEmissionTime = duration;
        }
        
        /** Stops emitting new particles. Depending on 'clearParticles', the existing particles
         *  will either keep animating until they die or will be removed right away. */
        public function stop(clearParticles:Boolean=false):void
        {
            mEmissionTime = 0.0;
            if (clearParticles) clear();
        }
        /** Removes all currently active particles. */
        public function clear():void
        {
            mNumParticles = 0;
        }
        
        /** Returns an empty rectangle at the particle system's position. Calculating the
         *  actual bounds would be too expensive. */
        public override function getBounds(targetSpace:DisplayObject, 
                                           resultRect:Rectangle=null):Rectangle
        {
            if (resultRect == null) resultRect = new Rectangle();
            
            getTransformationMatrix(targetSpace, sHelperMatrix);
            MatrixUtil.transformCoords(sHelperMatrix, 0, 0, sHelperPoint);
            
            resultRect.x = sHelperPoint.x;
            resultRect.y = sHelperPoint.y;
            resultRect.width = resultRect.height = 0;
            
            return resultRect;
        }
        
        public function advanceTime(passedTime:Number):void
        {
            var particleIndex:int = 0;
            var particle:Particle;
            
            // advance existing particles
            
            while (particleIndex < mNumParticles)
            {
                particle = mParticles[particleIndex] as Particle;
                
                if (particle.currentTime < particle.totalTime)
                {
                    advanceParticle(particle, passedTime);
                    ++particleIndex;
                }
                else
                {
                    if (particleIndex != mNumParticles - 1)
                    {
                        var nextParticle:Particle = mParticles[int(mNumParticles-1)] as Particle;
                        mParticles[int(mNumParticles-1)] = particle;
                        mParticles[particleIndex] = nextParticle;
                    }
                    
                    --mNumParticles;
                    
                    if (mNumParticles == 0 && mEmissionTime == 0)
                        dispatchEvent(new Event(Event.COMPLETE));
                }
            }
            
            // create and advance new particles
            
            if (mEmissionTime > 0)
            {
                var timeBetweenParticles:Number = 1.0 / mEmissionRate;
                mFrameTime += passedTime;
                
                while (mFrameTime > 0)
                {
                    if (mNumParticles < mMaxCapacity)
                    {
                        if (mNumParticles == capacity)
                            raiseCapacity(capacity);
                    
                        particle = mParticles[mNumParticles] as Particle;
                        initParticle(particle);
                      
                        // particle might be dead at birth
                        if (particle.totalTime > 0.0)
                        {
                            advanceParticle(particle, mFrameTime);
                            ++mNumParticles
                         }
                    }
                    
                    mFrameTime -= timeBetweenParticles;
                }
                
                if (mEmissionTime != Number.MAX_VALUE)
                    mEmissionTime = Math.max(0.0, mEmissionTime - passedTime);
            }
            
            // update vertex data
            
            var vertexID:int = 0;
            var color:uint;
            var alpha:Number;
            var rotation:Number;
            var x:Number, y:Number;
            var xOffset:Number, yOffset:Number;
            var textureWidth:Number = mTexture.width;
            var textureHeight:Number = mTexture.height;
            
            for (var i:int=0; i<mNumParticles; ++i)
            {
                vertexID = i << 2;
                particle = mParticles[i] as Particle;
                color = particle.color;
                alpha = particle.alpha;
                rotation = particle.rotation;
                x = particle.x;
                y = particle.y;
                xOffset = textureWidth  * particle.scale >> 1;
                yOffset = textureHeight * particle.scale >> 1;
                
                for (var j:int=0; j<4; ++j) {
                    
                    if(mPremultipliedAlpha && alpha < MIN_ALPHA_PMA)
                    	alpha = MIN_ALPHA_PMA;
                    
                    var rgba:uint = ((color << 8) & 0xffffff00) | (int(alpha * 255.0) & 0xff);
                    
                    if (mPremultipliedAlpha) rgba = premultiplyAlpha(rgba);
                    
                    mRawVertexData.position = (vertexID+j) * BYTES_PER_VERTEX + COLOR_OFFSET_IN_BYTES;
                    mRawVertexData.writeUnsignedInt(switchEndian(rgba));

                }
                
                if (rotation)
                {
                    var cos:Number  = Math.cos(rotation);
                    var sin:Number  = Math.sin(rotation);
                    var cosX:Number = cos * xOffset;
                    var cosY:Number = cos * yOffset;
                    var sinX:Number = sin * xOffset;
                    var sinY:Number = sin * yOffset;
                    
                    mRawVertexData.position = vertexID * BYTES_PER_VERTEX + POSITION_OFFSET_IN_BYTES;
                    mRawVertexData.writeFloat( x - cosX + sinY );
                    mRawVertexData.writeFloat( y - sinX - cosY );
                    
                    mRawVertexData.position = (vertexID+1) * BYTES_PER_VERTEX + POSITION_OFFSET_IN_BYTES;
                    mRawVertexData.writeFloat( x + cosX + sinY );
                    mRawVertexData.writeFloat( y + sinX - cosY );
                    
                    mRawVertexData.position = (vertexID+2) * BYTES_PER_VERTEX + POSITION_OFFSET_IN_BYTES;
                    mRawVertexData.writeFloat(x - cosX - sinY);
                    mRawVertexData.writeFloat(y - sinX + cosY);
                    
                    mRawVertexData.position = (vertexID+3) * BYTES_PER_VERTEX + POSITION_OFFSET_IN_BYTES;
                    mRawVertexData.writeFloat(x + cosX - sinY);
                    mRawVertexData.writeFloat(y + sinX + cosY);
                }
                else 
                {
                    
                    mRawVertexData.position = vertexID * BYTES_PER_VERTEX + POSITION_OFFSET_IN_BYTES;
                    mRawVertexData.writeFloat( x - xOffset );
                    mRawVertexData.writeFloat( y - yOffset );
                    
                    mRawVertexData.position = (vertexID+1) * BYTES_PER_VERTEX + POSITION_OFFSET_IN_BYTES;
                    mRawVertexData.writeFloat( x + xOffset );
                    mRawVertexData.writeFloat( y - yOffset );
                    
                    mRawVertexData.position = (vertexID+2) * BYTES_PER_VERTEX + POSITION_OFFSET_IN_BYTES;
                    mRawVertexData.writeFloat(x - xOffset);
                    mRawVertexData.writeFloat(y + yOffset);
                    
                    mRawVertexData.position = (vertexID+3) * BYTES_PER_VERTEX + POSITION_OFFSET_IN_BYTES;
                    mRawVertexData.writeFloat(x + xOffset);
                    mRawVertexData.writeFloat(y + yOffset);

                }
            }
        }
        
        public override function render(support:RenderSupport, alpha:Number):void
        {
            if (mNumParticles == 0) return;
            
            // always call this method when you write custom rendering code!
            // it causes all previously batched quads/images to render.
            support.finishQuadBatch();
            
            // make this call to keep the statistics display in sync.
            // to play it safe, it's done in a backwards-compatible way here.
            if (support.hasOwnProperty("raiseDrawCount"))
                support.raiseDrawCount();
            
            alpha *= this.alpha;
            
            var context:Context3D = Starling.context;
            var pma:Boolean = texture.premultipliedAlpha;
            
            sRenderAlpha[0] = sRenderAlpha[1] = sRenderAlpha[2] = pma ? alpha : 1.0;
            sRenderAlpha[3] = alpha;
            
            if (context == null) throw new MissingContextError();
            
            mVertexBuffer.uploadFromByteArray(mRawVertexData, 0, 0, mNumParticles * 4);
            mIndexBuffer.uploadFromByteArray(mIndices,0 , 0, mNumParticles * 6);
            
            context.setBlendFactors(mBlendFactorSource, mBlendFactorDestination);
            context.setTextureAt(0, mTexture.base);
            
            context.setProgram(mProgram);
            context.setProgramConstantsFromMatrix(Context3DProgramType.VERTEX, 0, support.mvpMatrix3D, true);
            context.setProgramConstantsFromVector(Context3DProgramType.VERTEX, 4, sRenderAlpha, 1);
            context.setVertexBufferAt(0, mVertexBuffer, POSITION_OFFSET, Context3DVertexBufferFormat.FLOAT_2); 
            context.setVertexBufferAt(1, mVertexBuffer, COLOR_OFFSET,    Context3DVertexBufferFormat.BYTES_4);
            context.setVertexBufferAt(2, mVertexBuffer, TEXCOORD_OFFSET, Context3DVertexBufferFormat.FLOAT_2);
            
            context.drawTriangles(mIndexBuffer, 0, mNumParticles * 2);
            
            context.setTextureAt(0, null);
            context.setVertexBufferAt(0, null);
            context.setVertexBufferAt(1, null);
            context.setVertexBufferAt(2, null);
        }
        
        /** Initialize the <tt>ParticleSystem</tt> with particles distributed randomly throughout
         *  their lifespans. */
        public function populate(count:int):void
        {
            count = Math.min(count, mMaxCapacity - mNumParticles);
            
            if (mNumParticles + count > capacity)
                raiseCapacity(count - capacity);
            
            var p:Particle;
            for (var i:int=0; i<count; i++)
            {
                p = mParticles[mNumParticles+i];
                initParticle(p);
                advanceParticle(p, Math.random() * p.totalTime);
            }
            
            mNumParticles += count;
        }
        
        // program management
        
        private function createProgram():void
        {
            var mipmap:Boolean = mTexture.mipMapping;
            var textureFormat:String = mTexture.format;
            var programName:String = "ext.ParticleSystem." + textureFormat + (mipmap ? "+mm" : "");
            
            mProgram = Starling.current.getProgram(programName);
            
            if (mProgram == null)
            {
                var textureOptions:String = "2d, clamp, linear, " + (mipmap ? "mipnearest" : "mipnone");
                
                if (textureFormat == Context3DTextureFormat.COMPRESSED)
                    textureOptions += ", dxt1";
                else if (textureFormat == "compressedAlpha")
                    textureOptions += ", dxt5";
                
                var vertexProgramCode:String =
                    "m44 op, va0, vc0 \n" + // 4x4 matrix transform to output clipspace
                    "mul v0, va1, vc4 \n" + // multiply color with alpha and pass to fragment program
                    "mov v1, va2      \n";  // pass texture coordinates to fragment program
                
                var fragmentProgramCode:String =
                    "tex ft1, v1, fs0 <" + textureOptions + "> \n" + // sample texture 0
                    "mul oc, ft1, v0";                               // multiply color with texel color
                
                var vertexProgramAssembler:AGALMiniAssembler = new AGALMiniAssembler();
                vertexProgramAssembler.assemble(Context3DProgramType.VERTEX, vertexProgramCode);
                
                var fragmentProgramAssembler:AGALMiniAssembler = new AGALMiniAssembler();
                fragmentProgramAssembler.assemble(Context3DProgramType.FRAGMENT, fragmentProgramCode);
                
                Starling.current.registerProgram(programName, 
                    vertexProgramAssembler.agalcode, fragmentProgramAssembler.agalcode);
                
                mProgram = Starling.current.getProgram(programName);
            }
        }
        
        [Inline]
        private final function switchEndian(value:uint):uint
        {
            return ( value        & 0xff) << 24 |
                ((value >>  8) & 0xff) << 16 |
                ((value >> 16) & 0xff) <<  8 |
                ((value >> 24) & 0xff);
        }
        
        [Inline]
        private final function premultiplyAlpha(rgba:uint):uint
        {
            var alpha:Number = (rgba & 0xff) / 255.0;
            
            if (alpha == 1.0) return rgba;
            else
            {
                var r:uint = ((rgba >> 24) & 0xff) * alpha;
                var g:uint = ((rgba >> 16) & 0xff) * alpha;
                var b:uint = ((rgba >>  8) & 0xff) * alpha;
                
                return (r & 0xff) << 24 |
                    (g & 0xff) << 16 |
                    (b & 0xff) <<  8 |
                    (rgba & 0xff);
            }
        }
        public function get isEmitting():Boolean { return mEmissionTime > 0 && mEmissionRate > 0; }
        public function get capacity():int { return mRawVertexData.length / BYTES_PER_VERTEX * 4; }
        public function get numParticles():int { return mNumParticles; }
        
        public function get maxCapacity():int { return mMaxCapacity; }
        public function set maxCapacity(value:int):void { mMaxCapacity = Math.min(8192, value); }
        
        public function get emissionRate():Number { return mEmissionRate; }
        public function set emissionRate(value:Number):void { mEmissionRate = value; }
        
        public function get emitterX():Number { return mEmitterX; }
        public function set emitterX(value:Number):void { mEmitterX = value; }
        
        public function get emitterY():Number { return mEmitterY; }
        public function set emitterY(value:Number):void { mEmitterY = value; }
        
        public function get blendFactorSource():String { return mBlendFactorSource; }
        public function set blendFactorSource(value:String):void { mBlendFactorSource = value; }
        
        public function get blendFactorDestination():String { return mBlendFactorDestination; }
        public function set blendFactorDestination(value:String):void { mBlendFactorDestination = value; }
        
        public function get texture():Texture { return mTexture; }
        public function set texture(value:Texture):void { mTexture = value; createProgram(); }
    }
}