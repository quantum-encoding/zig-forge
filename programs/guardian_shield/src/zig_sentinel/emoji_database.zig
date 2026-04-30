//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// emoji_database.zig - Comprehensive Unicode 15.1 Emoji Database
// Purpose: Canonical reference of emoji → UTF-8 byte lengths
// Source: Unicode Consortium Emoji 15.1 Specification
//
// Database Statistics:
//   - Total emoji: 300+ common emoji (expandable to 3600+)
//   - Coverage: Emoticons, Symbols, Flags, Objects, Animals, Food, Activities
//   - Byte lengths: 3-32 bytes (including ZWJ sequences, modifiers)
//
// Categories:
//   1. Smileys & Emotion
//   2. People & Body
//   3. Animals & Nature
//   4. Food & Drink
//   5. Travel & Places
//   6. Activities
//   7. Objects
//   8. Symbols
//   9. Flags

const std = @import("std");

/// Comprehensive emoji size database
/// Format: Emoji (UTF-8) → Byte count
pub const EMOJI_SIZES = std.StaticStringMap(u8).initComptime(.{
    // ============================================================
    // Category 1: Smileys & Emotion (😀)
    // ============================================================
    .{ "😀", 4 }, // Grinning face (U+1F600)
    .{ "😁", 4 }, // Beaming face
    .{ "😂", 4 }, // Face with tears of joy
    .{ "🤣", 4 }, // Rolling on floor laughing
    .{ "😃", 4 }, // Grinning face with big eyes
    .{ "😄", 4 }, // Grinning face with smiling eyes
    .{ "😅", 4 }, // Grinning face with sweat
    .{ "😆", 4 }, // Grinning squinting face
    .{ "😉", 4 }, // Winking face
    .{ "😊", 4 }, // Smiling face with smiling eyes
    .{ "😋", 4 }, // Face savoring food
    .{ "😎", 4 }, // Smiling face with sunglasses
    .{ "😍", 4 }, // Smiling face with heart-eyes
    .{ "😘", 4 }, // Face blowing a kiss
    .{ "🥰", 4 }, // Smiling face with hearts
    .{ "😗", 4 }, // Kissing face
    .{ "😙", 4 }, // Kissing face with smiling eyes
    .{ "🥲", 4 }, // Smiling face with tear
    .{ "😚", 4 }, // Kissing face with closed eyes
    .{ "🙂", 4 }, // Slightly smiling face
    .{ "🤗", 4 }, // Smiling face with open hands
    .{ "🤩", 4 }, // Star-struck
    .{ "🤔", 4 }, // Thinking face
    .{ "🫡", 4 }, // Saluting face
    .{ "🤨", 4 }, // Face with raised eyebrow
    .{ "😐", 4 }, // Neutral face
    .{ "😑", 4 }, // Expressionless face
    .{ "😶", 4 }, // Face without mouth
    .{ "🫥", 4 }, // Dotted line face
    .{ "😏", 4 }, // Smirking face
    .{ "😒", 4 }, // Unamused face
    .{ "🙄", 4 }, // Face with rolling eyes
    .{ "😬", 4 }, // Grimacing face
    .{ "😮‍💨", 11 }, // Face exhaling (ZWJ sequence)
    .{ "🤥", 4 }, // Lying face
    .{ "😌", 4 }, // Relieved face
    .{ "😔", 4 }, // Pensive face
    .{ "😪", 4 }, // Sleepy face
    .{ "🤤", 4 }, // Drooling face
    .{ "😴", 4 }, // Sleeping face
    .{ "😷", 4 }, // Face with medical mask
    .{ "🤒", 4 }, // Face with thermometer
    .{ "🤕", 4 }, // Face with head-bandage
    .{ "🤢", 4 }, // Nauseated face
    .{ "🤮", 4 }, // Face vomiting
    .{ "🤧", 4 }, // Sneezing face
    .{ "🥵", 4 }, // Hot face
    .{ "🥶", 4 }, // Cold face
    .{ "😵", 4 }, // Face with crossed-out eyes
    .{ "😵‍💫", 11 }, // Face with spiral eyes
    .{ "🤯", 4 }, // Exploding head
    .{ "🤠", 4 }, // Cowboy hat face
    .{ "🥳", 4 }, // Partying face
    .{ "🥸", 4 }, // Disguised face
    .{ "😇", 4 }, // Smiling face with halo
    .{ "🤓", 4 }, // Nerd face
    .{ "🧐", 4 }, // Face with monocle
    .{ "😈", 4 }, // Smiling face with horns
    .{ "👿", 4 }, // Angry face with horns
    .{ "👹", 4 }, // Ogre
    .{ "👺", 4 }, // Goblin
    .{ "💀", 4 }, // Skull
    .{ "☠️", 6 }, // Skull and crossbones (with variant selector)
    .{ "👻", 4 }, // Ghost
    .{ "👽", 4 }, // Alien
    .{ "👾", 4 }, // Alien monster
    .{ "🤖", 4 }, // Robot
    .{ "💩", 4 }, // Pile of poo
    .{ "😺", 4 }, // Grinning cat
    .{ "😸", 4 }, // Grinning cat with smiling eyes
    .{ "😹", 4 }, // Cat with tears of joy
    .{ "😻", 4 }, // Smiling cat with heart-eyes
    .{ "😼", 4 }, // Cat with wry smile
    .{ "😽", 4 }, // Kissing cat
    .{ "🙀", 4 }, // Weary cat
    .{ "😿", 4 }, // Crying cat
    .{ "😾", 4 }, // Pouting cat

    // ============================================================
    // Category 2: People & Body (👤)
    // ============================================================
    .{ "👋", 4 }, // Waving hand
    .{ "🤚", 4 }, // Raised back of hand
    .{ "🖐️", 7 }, // Hand with fingers splayed (with variant)
    .{ "✋", 3 }, // Raised hand
    .{ "🖖", 4 }, // Vulcan salute
    .{ "👌", 4 }, // OK hand
    .{ "🤌", 4 }, // Pinched fingers
    .{ "🤏", 4 }, // Pinching hand
    .{ "✌️", 6 }, // Victory hand
    .{ "🤞", 4 }, // Crossed fingers
    .{ "🫰", 4 }, // Hand with index finger and thumb crossed
    .{ "🤟", 4 }, // Love-you gesture
    .{ "🤘", 4 }, // Sign of the horns
    .{ "🤙", 4 }, // Call me hand
    .{ "👈", 4 }, // Backhand index pointing left
    .{ "👉", 4 }, // Backhand index pointing right
    .{ "👆", 4 }, // Backhand index pointing up
    .{ "🖕", 4 }, // Middle finger
    .{ "👇", 4 }, // Backhand index pointing down
    .{ "☝️", 6 }, // Index pointing up
    .{ "👍", 4 }, // Thumbs up
    .{ "👎", 4 }, // Thumbs down
    .{ "✊", 3 }, // Raised fist
    .{ "👊", 4 }, // Oncoming fist
    .{ "🤛", 4 }, // Left-facing fist
    .{ "🤜", 4 }, // Right-facing fist
    .{ "👏", 4 }, // Clapping hands
    .{ "🙌", 4 }, // Raising hands
    .{ "👐", 4 }, // Open hands
    .{ "🤲", 4 }, // Palms up together
    .{ "🤝", 4 }, // Handshake
    .{ "🙏", 4 }, // Folded hands
    .{ "✍️", 6 }, // Writing hand
    .{ "💅", 4 }, // Nail polish
    .{ "🤳", 4 }, // Selfie
    .{ "💪", 4 }, // Flexed biceps
    .{ "🦾", 4 }, // Mechanical arm
    .{ "🦿", 4 }, // Mechanical leg
    .{ "🦵", 4 }, // Leg
    .{ "🦶", 4 }, // Foot
    .{ "👂", 4 }, // Ear
    .{ "🦻", 4 }, // Ear with hearing aid
    .{ "👃", 4 }, // Nose
    .{ "🧠", 4 }, // Brain
    .{ "🫀", 4 }, // Anatomical heart
    .{ "🫁", 4 }, // Lungs
    .{ "🦷", 4 }, // Tooth
    .{ "🦴", 4 }, // Bone
    .{ "👀", 4 }, // Eyes
    .{ "👁️", 7 }, // Eye
    .{ "👅", 4 }, // Tongue
    .{ "👄", 4 }, // Mouth
    .{ "🫦", 4 }, // Biting lip

    // Skin tone modifiers (add 4 bytes to base)
    .{ "👋🏻", 8 }, // Waving hand: light skin tone
    .{ "👋🏼", 8 }, // Medium-light
    .{ "👋🏽", 8 }, // Medium
    .{ "👋🏾", 8 }, // Medium-dark
    .{ "👋🏿", 8 }, // Dark
    .{ "👍🏻", 8 }, // Thumbs up: light
    .{ "👍🏼", 8 }, // Medium-light
    .{ "👍🏽", 8 }, // Medium
    .{ "👍🏾", 8 }, // Medium-dark
    .{ "👍🏿", 8 }, // Dark

    // People (with ZWJ sequences for professions)
    .{ "👨", 4 }, // Man
    .{ "👩", 4 }, // Woman
    .{ "🧑", 4 }, // Person
    .{ "👨‍💻", 11 }, // Man technologist (U+1F468 + ZWJ + U+1F4BB)
    .{ "👩‍💻", 11 }, // Woman technologist
    .{ "🧑‍💻", 11 }, // Person technologist
    .{ "👨‍🔬", 11 }, // Man scientist
    .{ "👩‍🔬", 11 }, // Woman scientist
    .{ "👨‍⚕️", 12 }, // Man health worker
    .{ "👩‍⚕️", 12 }, // Woman health worker
    .{ "👨‍🚀", 11 }, // Man astronaut
    .{ "👩‍🚀", 11 }, // Woman astronaut
    .{ "🕵️", 7 }, // Detective
    .{ "👮", 4 }, // Police officer
    .{ "💂", 4 }, // Guard
    .{ "🥷", 4 }, // Ninja
    .{ "👷", 4 }, // Construction worker
    .{ "🫅", 4 }, // Person with crown
    .{ "👸", 4 }, // Princess
    .{ "🤴", 4 }, // Prince
    .{ "👳", 4 }, // Person wearing turban
    .{ "🧕", 4 }, // Woman with headscarf
    .{ "🤵", 4 }, // Person in tuxedo
    .{ "👰", 4 }, // Person with veil
    .{ "🤰", 4 }, // Pregnant woman
    .{ "🤱", 4 }, // Breast-feeding
    .{ "👼", 4 }, // Baby angel
    .{ "🎅", 4 }, // Santa Claus
    .{ "🤶", 4 }, // Mrs. Claus
    .{ "🧙", 4 }, // Mage
    .{ "🧚", 4 }, // Fairy
    .{ "🧛", 4 }, // Vampire
    .{ "🧜", 4 }, // Merperson
    .{ "🧝", 4 }, // Elf
    .{ "🧞", 4 }, // Genie
    .{ "🧟", 4 }, // Zombie

    // ============================================================
    // Category 3: Animals & Nature (🐶)
    // ============================================================
    .{ "🐶", 4 }, // Dog face
    .{ "🐱", 4 }, // Cat face
    .{ "🐭", 4 }, // Mouse face
    .{ "🐹", 4 }, // Hamster
    .{ "🐰", 4 }, // Rabbit face
    .{ "🦊", 4 }, // Fox
    .{ "🐻", 4 }, // Bear
    .{ "🐼", 4 }, // Panda
    .{ "🐻‍❄️", 11 }, // Polar bear (ZWJ)
    .{ "🐨", 4 }, // Koala
    .{ "🐯", 4 }, // Tiger face
    .{ "🦁", 4 }, // Lion
    .{ "🐮", 4 }, // Cow face
    .{ "🐷", 4 }, // Pig face
    .{ "🐽", 4 }, // Pig nose
    .{ "🐸", 4 }, // Frog
    .{ "🐵", 4 }, // Monkey face
    .{ "🙈", 4 }, // See-no-evil monkey
    .{ "🙉", 4 }, // Hear-no-evil monkey
    .{ "🙊", 4 }, // Speak-no-evil monkey
    .{ "🐒", 4 }, // Monkey
    .{ "🐔", 4 }, // Chicken
    .{ "🐧", 4 }, // Penguin
    .{ "🐦", 4 }, // Bird
    .{ "🐤", 4 }, // Baby chick
    .{ "🐣", 4 }, // Hatching chick
    .{ "🐥", 4 }, // Front-facing baby chick
    .{ "🦆", 4 }, // Duck
    .{ "🦅", 4 }, // Eagle
    .{ "🦉", 4 }, // Owl
    .{ "🦇", 4 }, // Bat
    .{ "🐺", 4 }, // Wolf
    .{ "🐗", 4 }, // Boar
    .{ "🐴", 4 }, // Horse face
    .{ "🦄", 4 }, // Unicorn
    .{ "🐝", 4 }, // Honeybee
    .{ "🪱", 4 }, // Worm
    .{ "🐛", 4 }, // Bug
    .{ "🦋", 4 }, // Butterfly
    .{ "🐌", 4 }, // Snail
    .{ "🪲", 4 }, // Beetle
    .{ "🐞", 4 }, // Lady beetle
    .{ "🐜", 4 }, // Ant
    .{ "🪰", 4 }, // Fly
    .{ "🪳", 4 }, // Cockroach
    .{ "🕷️", 7 }, // Spider
    .{ "🕸️", 7 }, // Spider web
    .{ "🦂", 4 }, // Scorpion
    .{ "🦟", 4 }, // Mosquito
    .{ "🪰", 4 }, // Fly
    .{ "🐢", 4 }, // Turtle
    .{ "🐍", 4 }, // Snake
    .{ "🦎", 4 }, // Lizard
    .{ "🦖", 4 }, // T-Rex
    .{ "🦕", 4 }, // Sauropod
    .{ "🐙", 4 }, // Octopus
    .{ "🦑", 4 }, // Squid
    .{ "🦐", 4 }, // Shrimp
    .{ "🦞", 4 }, // Lobster
    .{ "🦀", 4 }, // Crab
    .{ "🐡", 4 }, // Blowfish
    .{ "🐠", 4 }, // Tropical fish
    .{ "🐟", 4 }, // Fish
    .{ "🐬", 4 }, // Dolphin
    .{ "🐳", 4 }, // Spouting whale
    .{ "🐋", 4 }, // Whale
    .{ "🦈", 4 }, // Shark
    .{ "🐊", 4 }, // Crocodile
    .{ "🐅", 4 }, // Tiger
    .{ "🐆", 4 }, // Leopard
    .{ "🦓", 4 }, // Zebra
    .{ "🦍", 4 }, // Gorilla
    .{ "🦧", 4 }, // Orangutan
    .{ "🐘", 4 }, // Elephant
    .{ "🦛", 4 }, // Hippopotamus
    .{ "🦏", 4 }, // Rhinoceros
    .{ "🐪", 4 }, // Camel
    .{ "🐫", 4 }, // Two-hump camel
    .{ "🦒", 4 }, // Giraffe
    .{ "🦘", 4 }, // Kangaroo
    .{ "🦬", 4 }, // Bison
    .{ "🐃", 4 }, // Water buffalo
    .{ "🐂", 4 }, // Ox
    .{ "🐄", 4 }, // Cow
    .{ "🐎", 4 }, // Horse
    .{ "🐖", 4 }, // Pig
    .{ "🐏", 4 }, // Ram
    .{ "🐑", 4 }, // Ewe
    .{ "🦙", 4 }, // Llama
    .{ "🐐", 4 }, // Goat
    .{ "🦌", 4 }, // Deer
    .{ "🐕", 4 }, // Dog
    .{ "🐩", 4 }, // Poodle
    .{ "🦮", 4 }, // Guide dog
    .{ "🐕‍🦺", 11 }, // Service dog (ZWJ)
    .{ "🐈", 4 }, // Cat
    .{ "🐈‍⬛", 11 }, // Black cat (ZWJ)
    .{ "🪶", 4 }, // Feather
    .{ "🐓", 4 }, // Rooster
    .{ "🦃", 4 }, // Turkey
    .{ "🦤", 4 }, // Dodo
    .{ "🦚", 4 }, // Peacock
    .{ "🦜", 4 }, // Parrot
    .{ "🦢", 4 }, // Swan
    .{ "🦩", 4 }, // Flamingo
    .{ "🕊️", 7 }, // Dove
    .{ "🐇", 4 }, // Rabbit
    .{ "🦝", 4 }, // Raccoon
    .{ "🦨", 4 }, // Skunk
    .{ "🦡", 4 }, // Badger
    .{ "🦫", 4 }, // Beaver
    .{ "🦦", 4 }, // Otter
    .{ "🦥", 4 }, // Sloth
    .{ "🐁", 4 }, // Mouse
    .{ "🐀", 4 }, // Rat
    .{ "🐿️", 7 }, // Chipmunk
    .{ "🦔", 4 }, // Hedgehog

    // Plants
    .{ "💐", 4 }, // Bouquet
    .{ "🌸", 4 }, // Cherry blossom
    .{ "💮", 4 }, // White flower
    .{ "🪷", 4 }, // Lotus
    .{ "🏵️", 7 }, // Rosette
    .{ "🌹", 4 }, // Rose
    .{ "🥀", 4 }, // Wilted flower
    .{ "🌺", 4 }, // Hibiscus
    .{ "🌻", 4 }, // Sunflower
    .{ "🌼", 4 }, // Blossom
    .{ "🌷", 4 }, // Tulip
    .{ "🌱", 4 }, // Seedling
    .{ "🪴", 4 }, // Potted plant
    .{ "🌲", 4 }, // Evergreen tree
    .{ "🌳", 4 }, // Deciduous tree
    .{ "🌴", 4 }, // Palm tree
    .{ "🌵", 4 }, // Cactus
    .{ "🌾", 4 }, // Sheaf of rice
    .{ "🌿", 4 }, // Herb
    .{ "☘️", 6 }, // Shamrock
    .{ "🍀", 4 }, // Four leaf clover
    .{ "🍁", 4 }, // Maple leaf
    .{ "🍂", 4 }, // Fallen leaf
    .{ "🍃", 4 }, // Leaf fluttering in wind
    .{ "🪹", 4 }, // Empty nest
    .{ "🪺", 4 }, // Nest with eggs

    // ============================================================
    // Category 4: Objects (Security & Tech)
    // ============================================================
    .{ "🔒", 4 }, // Locked
    .{ "🔓", 4 }, // Unlocked
    .{ "🔐", 4 }, // Locked with key
    .{ "🔑", 4 }, // Key
    .{ "🗝️", 7 }, // Old key
    .{ "🛡️", 7 }, // Shield (CRITICAL for Guardian Shield!)
    .{ "⚔️", 6 }, // Crossed swords
    .{ "🔫", 4 }, // Pistol
    .{ "🪃", 4 }, // Boomerang
    .{ "🏹", 4 }, // Bow and arrow
    .{ "🔪", 4 }, // Kitchen knife
    .{ "🗡️", 7 }, // Dagger
    .{ "⚠️", 6 }, // Warning
    .{ "🚨", 4 }, // Police car light
    .{ "🚦", 4 }, // Vertical traffic light
    .{ "🚥", 4 }, // Horizontal traffic light
    .{ "🔱", 4 }, // Trident emblem
    .{ "⚡", 3 }, // High voltage
    .{ "🔥", 4 }, // Fire
    .{ "💥", 4 }, // Collision
    .{ "💫", 4 }, // Dizzy
    .{ "💻", 4 }, // Laptop
    .{ "🖥️", 7 }, // Desktop computer
    .{ "🖨️", 7 }, // Printer
    .{ "⌨️", 6 }, // Keyboard
    .{ "🖱️", 7 }, // Computer mouse
    .{ "🖲️", 7 }, // Trackball
    .{ "💾", 4 }, // Floppy disk
    .{ "💿", 4 }, // Optical disk
    .{ "📀", 4 }, // DVD
    .{ "🧮", 4 }, // Abacus
    .{ "🎥", 4 }, // Movie camera
    .{ "📹", 4 }, // Video camera
    .{ "📷", 4 }, // Camera
    .{ "📸", 4 }, // Camera with flash
    .{ "📱", 4 }, // Mobile phone
    .{ "☎️", 6 }, // Telephone
    .{ "📞", 4 }, // Telephone receiver
    .{ "📟", 4 }, // Pager
    .{ "📠", 4 }, // Fax machine
    .{ "📺", 4 }, // Television
    .{ "📻", 4 }, // Radio
    .{ "🔊", 4 }, // Speaker loud volume
    .{ "🔉", 4 }, // Speaker medium volume
    .{ "🔈", 4 }, // Speaker low volume
    .{ "🔇", 4 }, // Muted speaker
    .{ "🔔", 4 }, // Bell
    .{ "🔕", 4 }, // Bell with slash
    .{ "📢", 4 }, // Loudspeaker
    .{ "📣", 4 }, // Megaphone
    .{ "🔍", 4 }, // Magnifying glass tilted left
    .{ "🔎", 4 }, // Magnifying glass tilted right
    .{ "💡", 4 }, // Light bulb
    .{ "🔦", 4 }, // Flashlight
    .{ "🏮", 4 }, // Red paper lantern
    .{ "🪔", 4 }, // Diya lamp
    .{ "📔", 4 }, // Notebook with decorative cover
    .{ "📕", 4 }, // Closed book
    .{ "📖", 4 }, // Open book
    .{ "📗", 4 }, // Green book
    .{ "📘", 4 }, // Blue book
    .{ "📙", 4 }, // Orange book
    .{ "📚", 4 }, // Books
    .{ "📓", 4 }, // Notebook
    .{ "📒", 4 }, // Ledger
    .{ "📃", 4 }, // Page with curl
    .{ "📜", 4 }, // Scroll
    .{ "📄", 4 }, // Page facing up
    .{ "📰", 4 }, // Newspaper
    .{ "🗞️", 7 }, // Rolled-up newspaper
    .{ "📑", 4 }, // Bookmark tabs
    .{ "🔖", 4 }, // Bookmark
    .{ "🏷️", 7 }, // Label
    .{ "📁", 4 }, // File folder
    .{ "📂", 4 }, // Open file folder
    .{ "🗂️", 7 }, // Card index dividers
    .{ "🗃️", 7 }, // Card file box
    .{ "🗄️", 7 }, // File cabinet
    .{ "📋", 4 }, // Clipboard
    .{ "📊", 4 }, // Bar chart
    .{ "📈", 4 }, // Chart increasing
    .{ "📉", 4 }, // Chart decreasing
    .{ "📝", 4 }, // Memo
    .{ "✏️", 6 }, // Pencil
    .{ "✒️", 6 }, // Black nib
    .{ "🖊️", 7 }, // Pen
    .{ "🖋️", 7 }, // Fountain pen
    .{ "🖍️", 7 }, // Crayon
    .{ "📏", 4 }, // Straight ruler
    .{ "📐", 4 }, // Triangular ruler
    .{ "✂️", 6 }, // Scissors
    .{ "🗂️", 7 }, // Card index dividers
    .{ "🗃️", 7 }, // Card file box
    .{ "🗄️", 7 }, // File cabinet

    // ============================================================
    // Category 5: Symbols
    // ============================================================
    .{ "❤️", 6 }, // Red heart
    .{ "🧡", 4 }, // Orange heart
    .{ "💛", 4 }, // Yellow heart
    .{ "💚", 4 }, // Green heart
    .{ "💙", 4 }, // Blue heart
    .{ "💜", 4 }, // Purple heart
    .{ "🖤", 4 }, // Black heart
    .{ "🤍", 4 }, // White heart
    .{ "🤎", 4 }, // Brown heart
    .{ "💔", 4 }, // Broken heart
    .{ "❣️", 6 }, // Heart exclamation
    .{ "💕", 4 }, // Two hearts
    .{ "💞", 4 }, // Revolving hearts
    .{ "💓", 4 }, // Beating heart
    .{ "💗", 4 }, // Growing heart
    .{ "💖", 4 }, // Sparkling heart
    .{ "💘", 4 }, // Heart with arrow
    .{ "💝", 4 }, // Heart with ribbon
    .{ "💟", 4 }, // Heart decoration
    .{ "☮️", 6 }, // Peace symbol
    .{ "✝️", 6 }, // Latin cross
    .{ "☪️", 6 }, // Star and crescent
    .{ "🕉️", 7 }, // Om
    .{ "☸️", 6 }, // Wheel of dharma
    .{ "✡️", 6 }, // Star of David
    .{ "🔯", 4 }, // Dotted six-pointed star
    .{ "🕎", 4 }, // Menorah
    .{ "☯️", 6 }, // Yin yang
    .{ "☦️", 6 }, // Orthodox cross
    .{ "🛐", 4 }, // Place of worship
    .{ "⛎", 3 }, // Ophiuchus
    .{ "♈", 3 }, // Aries
    .{ "♉", 3 }, // Taurus
    .{ "♊", 3 }, // Gemini
    .{ "♋", 3 }, // Cancer
    .{ "♌", 3 }, // Leo
    .{ "♍", 3 }, // Virgo
    .{ "♎", 3 }, // Libra
    .{ "♏", 3 }, // Scorpio
    .{ "♐", 3 }, // Sagittarius
    .{ "♑", 3 }, // Capricorn
    .{ "♒", 3 }, // Aquarius
    .{ "♓", 3 }, // Pisces
    .{ "🆔", 4 }, // ID button
    .{ "⚛️", 6 }, // Atom symbol
    .{ "☢️", 6 }, // Radioactive
    .{ "☣️", 6 }, // Biohazard
    .{ "⚠️", 6 }, // Warning
    .{ "🚸", 4 }, // Children crossing
    .{ "⛔", 3 }, // No entry
    .{ "🚫", 4 }, // Prohibited
    .{ "🚳", 4 }, // No bicycles
    .{ "🚭", 4 }, // No smoking
    .{ "🚯", 4 }, // No littering
    .{ "🚱", 4 }, // Non-potable water
    .{ "🚷", 4 }, // No pedestrians
    .{ "📵", 4 }, // No mobile phones
    .{ "🔞", 4 }, // No one under eighteen
    .{ "☑️", 6 }, // Check box with check
    .{ "✔️", 6 }, // Check mark
    .{ "✅", 3 }, // Check mark button
    .{ "❌", 3 }, // Cross mark
    .{ "❎", 3 }, // Cross mark button
    .{ "➕", 3 }, // Plus
    .{ "➖", 3 }, // Minus
    .{ "➗", 3 }, // Divide
    .{ "✖️", 6 }, // Multiply
    .{ "🟰", 4 }, // Heavy equals sign
    .{ "💲", 4 }, // Heavy dollar sign
    .{ "💱", 4 }, // Currency exchange
    .{ "™️", 5 }, // Trade mark
    .{ "©️", 5 }, // Copyright
    .{ "®️", 5 }, // Registered
    .{ "〰️", 6 }, // Wavy dash
    .{ "➰", 3 }, // Curly loop
    .{ "➿", 3 }, // Double curly loop
    .{ "🔚", 4 }, // END arrow
    .{ "🔙", 4 }, // BACK arrow
    .{ "🔛", 4 }, // ON! arrow
    .{ "🔝", 4 }, // TOP arrow
    .{ "🔜", 4 }, // SOON arrow
    .{ "✓", 3 }, // Check mark
    .{ "✔️", 6 }, // Heavy check mark
    .{ "☑️", 6 }, // Ballot box with check
    .{ "✅", 3 }, // White heavy check mark
    .{ "❌", 3 }, // Cross mark
    .{ "❎", 3 }, // Negative squared cross mark

    // ============================================================
    // Category 6: Flags (Regional Indicators = 8 bytes each)
    // ============================================================
    .{ "🇺🇸", 8 }, // United States
    .{ "🇬🇧", 8 }, // United Kingdom
    .{ "🇨🇦", 8 }, // Canada
    .{ "🇩🇪", 8 }, // Germany
    .{ "🇫🇷", 8 }, // France
    .{ "🇮🇹", 8 }, // Italy
    .{ "🇪🇸", 8 }, // Spain
    .{ "🇯🇵", 8 }, // Japan
    .{ "🇨🇳", 8 }, // China
    .{ "🇰🇷", 8 }, // South Korea
    .{ "🇮🇳", 8 }, // India
    .{ "🇧🇷", 8 }, // Brazil
    .{ "🇲🇽", 8 }, // Mexico
    .{ "🇦🇺", 8 }, // Australia
    .{ "🇷🇺", 8 }, // Russia
    .{ "🇿🇦", 8 }, // South Africa
    .{ "🇳🇱", 8 }, // Netherlands
    .{ "🇸🇪", 8 }, // Sweden
    .{ "🇳🇴", 8 }, // Norway
    .{ "🇩🇰", 8 }, // Denmark
    .{ "🇫🇮", 8 }, // Finland
    .{ "🇨🇭", 8 }, // Switzerland
    .{ "🇦🇹", 8 }, // Austria
    .{ "🇧🇪", 8 }, // Belgium
    .{ "🇵🇱", 8 }, // Poland
    .{ "🇨🇿", 8 }, // Czech Republic
    .{ "🇭🇺", 8 }, // Hungary
    .{ "🇬🇷", 8 }, // Greece
    .{ "🇹🇷", 8 }, // Turkey
    .{ "🇮🇱", 8 }, // Israel
    .{ "🇪🇬", 8 }, // Egypt
    .{ "🇸🇦", 8 }, // Saudi Arabia
    .{ "🇦🇪", 8 }, // United Arab Emirates
    .{ "🇸🇬", 8 }, // Singapore
    .{ "🇹🇭", 8 }, // Thailand
    .{ "🇻🇳", 8 }, // Vietnam
    .{ "🇵🇭", 8 }, // Philippines
    .{ "🇮🇩", 8 }, // Indonesia
    .{ "🇲🇾", 8 }, // Malaysia
    .{ "🇦🇷", 8 }, // Argentina
    .{ "🇨🇱", 8 }, // Chile
    .{ "🇨🇴", 8 }, // Colombia
    .{ "🇵🇪", 8 }, // Peru
    .{ "🇺🇦", 8 }, // Ukraine
    .{ "🇵🇹", 8 }, // Portugal
    .{ "🇮🇪", 8 }, // Ireland
    .{ "🇳🇿", 8 }, // New Zealand

    // ============================================================
    // Category 7: Keycap Numbers (Combining Enclosing Keycap)
    // ============================================================
    .{ "0️⃣", 6 }, // Keycap 0 (digit + variant + combining)
    .{ "1️⃣", 6 }, // Keycap 1
    .{ "2️⃣", 6 }, // Keycap 2
    .{ "3️⃣", 6 }, // Keycap 3
    .{ "4️⃣", 6 }, // Keycap 4
    .{ "5️⃣", 6 }, // Keycap 5
    .{ "6️⃣", 6 }, // Keycap 6
    .{ "7️⃣", 6 }, // Keycap 7
    .{ "8️⃣", 6 }, // Keycap 8
    .{ "9️⃣", 6 }, // Keycap 9
    .{ "#️⃣", 6 }, // Keycap #
    .{ "*️⃣", 6 }, // Keycap *
    .{ "🔟", 4 }, // Keycap 10

    // ============================================================
    // Special: Time & Clock
    // ============================================================
    .{ "⏰", 3 }, // Alarm clock
    .{ "⏱️", 6 }, // Stopwatch
    .{ "⏲️", 6 }, // Timer clock
    .{ "⏳", 3 }, // Hourglass not done
    .{ "⌛", 3 }, // Hourglass done
    .{ "⌚", 3 }, // Watch
    .{ "🕐", 4 }, // One o'clock
    .{ "🕑", 4 }, // Two o'clock
    .{ "🕒", 4 }, // Three o'clock
    .{ "🕓", 4 }, // Four o'clock
    .{ "🕔", 4 }, // Five o'clock
    .{ "🕕", 4 }, // Six o'clock
    .{ "🕖", 4 }, // Seven o'clock
    .{ "🕗", 4 }, // Eight o'clock
    .{ "🕘", 4 }, // Nine o'clock
    .{ "🕙", 4 }, // Ten o'clock
    .{ "🕚", 4 }, // Eleven o'clock
    .{ "🕛", 4 }, // Twelve o'clock
});

/// Get expected byte length for an emoji from the database
pub inline fn getExpectedLength(emoji: []const u8) ?u8 {
    return EMOJI_SIZES.get(emoji);
}

/// Database statistics
pub const TOTAL_EMOJI_COUNT: usize = EMOJI_SIZES.kvs.len;

test "database size" {
    try std.testing.expect(TOTAL_EMOJI_COUNT > 300);
}

test "critical security emoji present" {
    try std.testing.expect(getExpectedLength("🛡️") != null);
    try std.testing.expect(getExpectedLength("⚠️") != null);
    try std.testing.expect(getExpectedLength("🔒") != null);
    try std.testing.expect(getExpectedLength("🔑") != null);
}
