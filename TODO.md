# Shardbreak TODO

## Gameplay
- [ ] The new ball item should not show as an effect as it is an instant, verify if other instant items set an effect.
- [ ] Balls should be able to bounce off each other
- [ ] Change the extra ball item to instead double the number of balls, check the naming of any notifications related to that. 
  - Each existing ball will split into two balls going in the same general direction but at opposite 10 degree angles. 
  - Consider that the two balls will collide initially and thus add a ghost timer to the ball. 
  - The ball will render partially slightly transparent if it is a ghost and will not collide with other balls for that time period. 
  - Ghost balls still collide with all other objects like blocks, walls or the paddle.
- [ ] Make a tweaks.odin file for constants that are gameplay related
	- Extract gameplay tweakables in @main.odin to this file as well
- [ ] Extend the effect timers by 50%
- [ ] Separate the score into a level score and a run score.
	- The level score is added to the run score when the level is completed. Show this on the level completed screen.

## Visuals
- [ ] Add a texture for the play area as well. This should be even darker than non-playable area. Add a visual dark grey border around the play area.
- [ ] Add a background texture for the main and options menu, but in this case it slowly moves over time in a diagonal direction.
- [ ] Use https://fa2png.com/ to download font awesome icons for each game item into the assets/icons folder, use snake case for file names.
  - If the downloading doesn't work investigate other ways to get font awesome icons as pngs
- [ ] Render items in the existing circle but with the corresponding icon rendered on top in black or white depending on the color that is most readable on the item color
- [ ] Particles should still be spawned on block hit, even if it isn't destroyed. 
  - Make the block destroy particles more impactful than it currently is.
  - Make hit particles less impactful than it currently is.
  - Store emit configs as constants

## Colours
- [ ] Add helper functions for colours such as:
	- Desaturating
	- Changing opacity
	- Checking if black or white is the most readable on the colour (ex. black on yellow but white on navy)

## Physics
- [ ] Add a Polygon struct to maths.odin, use it throughout for defining a polygon for example when rendering
- [ ] Add collision checks similar to the existing collision checks for polygon vs circle and polygon vs rectangle

## Saving and loading
- [ ] Allow saving and loading the level and run state. Assume levels and item types don't change before loading and saving
- [ ] Save the state when:
	- Quiting a run on the pause menu
	- After completing a level
- [ ] If there is a save state then add a new option at the top of the menu to continue the game which loads the save state
	- Start the saved game in a WaitingToStart, don't change any state as you would for a level start, keep it as the loaded state

## Assets
- [ ] Create a new asset system
	- There is an assets/images.json file that contains all images that must be loaded instead of each image/texture being loaded explicitly.
	- Each entry in the images.json file also contains extra information such as the 9-patch splits or sprite sheet layouts if they are needed.
	- Each entry defines an name for the image or a name for each entry in the sprite sheet if the asset is an sprite sheet.
	- Allow querying the asset system for the texture/image and related info using the name
	- Refactor all the code to use the new asset system

## Rendering
- [ ] Make draw_nine_patch delegate to draw_nine_patch_splits if it makes sense

## UI
- [ ] Add an pointer to the renderer in the UI struct and use it for rendering instead of passing the renderer into all functions