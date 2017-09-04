{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-|
Module      : Hypercube.Game
Description : The main game loops and start function
Copyright   : (c) Jaro Reinders, 2017
License     : GPL-3
Maintainer  : noughtmare@openmailbox.org

This module contains the @start@ function, the @mainLoop@ and the @draw@ function.

TODO: find a better place for the @draw@ function.
-}

module Hypercube.Game where

import Hypercube.Chunk
import Hypercube.Types
import Hypercube.Config
import Hypercube.Util
import Hypercube.Shaders
import Hypercube.Input

import qualified Debug.Trace as D

import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.State
import Control.Lens
import Control.Concurrent
import Control.Exception
import Data.Maybe
import qualified Graphics.Rendering.OpenGL as GL
import qualified Graphics.GLUtil as U
import Graphics.UI.GLFW as GLFW
import Linear
import qualified Data.Vector as V
import qualified Data.Vector.Storable as VS
import qualified Data.Map.Strict as M
import Control.Concurrent.STM.TChan
import Control.Monad.STM
import Control.Applicative
import System.Exit
import qualified Data.ByteString as B
import Data.Int (Int8)
import Foreign.C.Types
import Foreign.Ptr
import System.Mem
import Data.List
import Data.IORef
import Foreign.Storable

data Timeout = Timeout
  deriving (Show)

instance Exception Timeout

timeout :: Int -> IO () -> IO ()
timeout microseconds action = do
  currentThreadId <- myThreadId
  forkIO $ threadDelay microseconds >> throwTo currentThreadId Timeout
  handle (\Timeout -> return ()) action

start :: IO ()
start = withWindow 1280 720 "Hypercube" $ \win -> do
  -- Disable the cursor
  GLFW.setCursorInputMode win GLFW.CursorInputMode'Disabled

  todo <- newIORef []
  chan <- newTChanIO
  startChunkManager todo chan


  -- Generate a new game world
  game <- Game (Camera (V3 8 15 8) 0 0 5 0.05)
           <$> (realToFrac . fromJust <$> GLFW.getTime)
           <*> (fmap realToFrac . uncurry V2 <$> GLFW.getCursorPos win)
           <*> pure M.empty

  void $ flip runStateT game $ do
    -- vsync
    liftIO $ GLFW.swapInterval 1

    p <- liftIO shaders

    -- Get the shader uniforms
    [modelLoc,viewLoc,projLoc] <- liftIO $
      mapM (GL.get . GL.uniformLocation p) ["model","view","projection"]

    liftIO $ do
      -- Set shader
      GL.currentProgram GL.$= Just p

      do -- Load texture & generate mipmaps
        (Right texture) <- U.readTexture "blocks.png"
        GL.textureBinding GL.Texture2D GL.$= Just texture
        GL.textureFilter  GL.Texture2D GL.$= ((GL.Nearest,Nothing),GL.Nearest)

        GL.generateMipmap' GL.Texture2D

      -- Set clear color
      GL.clearColor GL.$= GL.Color4 0.2 0.3 0.3 1

      GLFW.setKeyCallback win (Just keyCallback)

      GL.cullFace  GL.$= Just GL.Back
      GL.depthFunc GL.$= Just GL.Less

    mainLoop win todo chan viewLoc projLoc modelLoc

draw :: M44 Float -> GL.UniformLocation -> IORef [V3 Int] ->  StateT Game IO ()
draw vp modelLoc todo = do
  let
    render :: V3 Int -> StateT Game IO [V3 Int]
    render pos = do 
      m <- use world
      case M.lookup pos m of
        Nothing -> return [pos]
        Just c -> do
          liftIO (execStateT (renderChunk pos modelLoc) c) -- >>= (world %=) . M.insert v
          return []

  playerPos <- fmap ((`div` chunkSize) . floor) <$> use (cam . camPos)
  let r = renderDistance
  liftIO . atomicWriteIORef todo . concat =<< mapM render 
    (sortOn (distance (fmap fromIntegral playerPos) . fmap fromIntegral) $ do
      v <- liftA3 V3 [-r..r] [-r..r] [-r..r]
      let toRender :: V3 Int
          toRender = playerPos + v

          --normalized = liftA2 (^/) id (^. _w) $ projected

          projected :: V4 Float
          projected = vp !* model

          model :: V4 Float
          model = (identity & translation .~ (fromIntegral <$> (chunkSize *^ toRender))) 
               !* (1 & _xyz .~ fromIntegral chunkSize / 2)

          radius = fromIntegral chunkSize / 2 * sqrt 3 -- the radius of the circumscribed sphere
      guard $ projected ^. _z >= -radius
      --guard $ all ((<= 1 + radius / abs (projected ^. _w)) . abs) $ normalized ^. _xy
      return toRender)

mainLoop :: GLFW.Window -> IORef [V3 Int] -> TChan (V3 Int, Chunk, VS.Vector (V4 Int8)) 
  -> GL.UniformLocation -> GL.UniformLocation -> GL.UniformLocation -> StateT Game IO ()
mainLoop win todo chan viewLoc projLoc modelLoc = do
  shouldClose <- liftIO $ GLFW.windowShouldClose win
  unless shouldClose $ do

    liftIO GLFW.pollEvents

    deltaTime <- do
      currentFrame <- realToFrac . fromJust <$> liftIO GLFW.getTime
      deltaTime <- (currentFrame -) <$> use lastFrame
      lastFrame .= currentFrame
      return deltaTime

    -- liftIO $ print $ 1/deltaTime

    keyboard win deltaTime
    mouse win deltaTime

    -- Handle Window resize
    (width, height) <- liftIO $ GLFW.getFramebufferSize win
    liftIO $ GL.viewport GL.$=
      (GL.Position 0 0, GL.Size (fromIntegral width) (fromIntegral height))

    -- Clear buffers
    liftIO $ GL.clear [GL.ColorBuffer, GL.DepthBuffer]

    -- Change view matrix
    curCamPos  <- use (cam . camPos)
    curGaze <- use (cam . gaze)

    let view = lookAt curCamPos (curCamPos + curGaze) (V3 0 1 0)
    viewMat <- liftIO $ toGLmatrix view
    GL.uniform viewLoc GL.$= viewMat

    -- Change projection matrix
    let proj = perspective (pi / 4) (fromIntegral width / fromIntegral height) 0.1 1000
    projMat <- liftIO $ toGLmatrix proj
    GL.uniform projLoc GL.$= projMat

    do
      let
        loadVbos = do
          t <- liftIO $ (+ 0.004) . fromJust <$> GLFW.getTime
          liftIO (atomically (tryReadTChan chan)) >>= maybe (return ()) (\(pos,Chunk blk _ _ _,v) -> do
            m <- use world
            if pos `M.member` m then
              loadVbos
            else do
              --liftIO $ putStrLn ("loadVbos: " ++ show pos)
              let len = VS.length v
              vbo <- GL.genObjectName
              liftIO $ when (len > 0) $ do
                GL.bindBuffer GL.ArrayBuffer GL.$= Just vbo
                VS.unsafeWith v $ \ptr ->
                  GL.bufferData GL.ArrayBuffer GL.$= 
                    (CPtrdiff (fromIntegral (sizeOf (undefined :: V4 Int8) * len)), ptr, GL.StaticDraw)
                GL.bindBuffer GL.ArrayBuffer GL.$= Nothing
              world %= M.insert pos (Chunk blk vbo len False)
              t' <- liftIO $ fromJust <$> GLFW.getTime
              when (t' < t) loadVbos)
      loadVbos

    draw (proj !*! view) modelLoc todo

    liftIO $ GLFW.swapBuffers win

    liftIO $ performMinorGC

    mainLoop win todo chan viewLoc projLoc modelLoc

