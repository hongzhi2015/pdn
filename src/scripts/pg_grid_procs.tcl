namespace eval ::pdn {

    variable logical_viarules {}
    variable vias {}

#This file contains procedures that are used for PDN generation

    proc get_dir {layer_name} {
        if {[regexp {.*_PIN_(hor|ver)} $layer_name - dir]} {
            return $dir
        }
        
        set idx [lsearch $::met_layer_list $layer_name]
        return [lindex $::met_layer_dir $idx]
    }

    proc convert_viarules_to_def_units {} {
        global via_tech
        variable def_via_tech
        
        dict for {rule_name rule} $via_tech {
            dict set def_via_tech $rule_name [list \
                lower [list \
                    layer [dict get $rule lower layer] \
                    enclosure [lmap x [dict get $rule lower enclosure] {expr round($x * $::def_units)}] \
                ] \
                upper [list \
                    layer [dict get $rule upper layer] \
                    enclosure [lmap x [dict get $rule upper enclosure] {expr round($x * $::def_units)}] \
                ] \
                cut [list \
                    layer [dict get $rule cut layer] \
                    size [lmap x [dict get $rule cut size] {expr round($x * $::def_units)}] \
                    spacing [lmap x [dict get $rule cut spacing] {expr round($x * $::def_units)}] \
                ] \
            ]
        }
    }
    
    proc select_viainfo {lower} {
        variable def_via_tech

        if {$def_via_tech == {}} {
            convert_viarules_to_def_units
        }
        
        set layer_name $lower
        regexp {(.*)_PIN} $lower - layer_name
        
        return [dict filter $def_via_tech script {rule_name rule} {expr {[dict get $rule lower layer] == $layer_name}}]
    }
    
    # Given the via rule expressed in via_info, what is the via with the largest cut area that we can make
    proc get_via_option {lower_dir rule_name via_info x y width height} {
        set cut_width  [lindex [dict get $via_info cut size] 0]
        set cut_height [lindex [dict get $via_info cut size] 1]

        set lower_enclosure [expr min([join [dict get $via_info lower enclosure] ","])]
        set upper_enclosure [expr min([join [dict get $via_info upper enclosure] ","])]
        set max_lower_enclosure [expr max([join [dict get $via_info lower enclosure] ","])]
        set max_upper_enclosure [expr max([join [dict get $via_info upper enclosure] ","])]

        # What are the maximum number of rows and columns that we can fit in this space?
        set i 0
        set via_width_lower 0
        set via_width_upper 0
        while {$via_width_lower < $width && $via_width_upper < $width} {
            incr i
            set xcut_pitch [lindex [dict get $via_info cut spacing] 0]
            set via_width_lower [expr $cut_width + $xcut_pitch * ($i - 1) + 2 * $lower_enclosure]
            set via_width_upper [expr $cut_width + $xcut_pitch * ($i - 1) + 2 * $upper_enclosure]
        }
        set xcut_spacing [expr $xcut_pitch - $cut_width]
        set columns [expr $i - 1]

        set i 0
        set via_height_lower 0
        set via_height_upper 0
        while {$via_height_lower < $height && $via_height_upper < $height} {
            incr i
            set ycut_pitch [lindex [dict get $via_info cut spacing] 1]
            set via_height_lower [expr $cut_height + $ycut_pitch * ($i - 1) + 2 * $lower_enclosure]
            set via_height_upper [expr $cut_height + $ycut_pitch * ($i - 1) + 2 * $upper_enclosure]
        }
        set ycut_spacing [expr $ycut_pitch - $cut_height]
        set rows [expr $i - 1]

	set enc_width  [expr ($width  - ($cut_width   + $xcut_pitch * ($columns - 1))) / 2]
	set enc_height [expr ($height - ($cut_height  + $ycut_pitch * ($rows    - 1))) / 2]

        # Use the largest value of enclosure in the direction of the layer
        # Use the smallest value of enclosure perpendicular to direction of the layer
	if {$lower_dir == "hor"} {
            if {$enc_height < $max_lower_enclosure} {
                set xBotEnc [expr max($max_lower_enclosure,$enc_width)]
            } else {
                set xBotEnc $enc_width
            }
            set yBotEnc $enc_height
        } else {
            set xBotEnc $enc_width
            if {$enc_width < $max_lower_enclosure} {
                set yBotEnc [expr max($max_lower_enclosure,$enc_height)]
            } else {
                set yBotEnc $enc_height
            }
        }
        
        # Use the largest value of enclosure in the direction of the layer
        # Use the smallest value of enclosure perpendicular to direction of the layer
	if {[get_dir [dict get $via_info upper layer]] == "hor"} {
            if {$enc_height < $max_upper_enclosure} {
                set xTopEnc [expr max($max_upper_enclosure,$enc_width)]
            } else {
                set xTopEnc $enc_width
            }
            set yTopEnc $enc_height
        } else {
            set xTopEnc $enc_width
            if {$enc_width < $max_upper_enclosure} {
                set yTopEnc [expr max($max_upper_enclosure,$enc_height)]
            } else {
                set yTopEnc $enc_height
            }
        }
        
        set rule [list \
            rule $rule_name \
            cutsize [dict get $via_info cut size] \
            layers [list [dict get $via_info lower layer] [dict get $via_info cut layer] [dict get $via_info upper layer]] \
            cutspacing [lmap spacing [dict get $via_info cut spacing] size [dict get $via_info cut size] {expr $spacing - $size}] \
            rowcol [list $rows $columns] \
            enclosure [list $xBotEnc $yBotEnc $xTopEnc $yTopEnc] \
        ]
        
        return $rule
    }
    
    proc get_viarule_name {lower x y width height} {
        set rules [select_viainfo $lower]
        set first_key [lindex [dict keys $rules] 0]
        set cut_layer [dict get $rules $first_key cut layer]

        return ${cut_layer}_${width}x${height}
    }
    
    proc get_cut_area {rule} {
        return [expr [lindex [dict get $rule rowcol] 0] * [lindex [dict get $rule rowcol] 0] * [lindex [dict get $rule cutsize] 0] * [lindex [dict get $rule cutsize] 1]]
    }
    
    proc select_rule {rule1 rule2} {
        if {[get_cut_area $rule2] > [get_cut_area $rule1]} {
            return $rule2
        }
        return $rule1
    }
    
    proc get_via {lower x y width height} {
        # First cur will assume that all crossing points (x y) are on grid for both lower and upper layers
        # TODO: Refine the algorithm to cope with offgrid intersection points
        variable physical_viarules
        
        set rule_name [get_viarule_name $lower $x $y $width $height]

        if {![dict exists $physical_viarules $rule_name]} {
            set selected_rule {}

            dict for {name rule} [select_viainfo $lower] {
                set result [get_via_option [get_dir $lower] $name $rule $x $y $width $height]
                if {$selected_rule == {}} {
                    set selected_rule $result
                } else {
                    # Choose the best between selected rule and current result, the winner becomes the new selected rule
                    set selected_rule [select_rule $selected_rule $result]
                }
            }

            dict set physical_viarules $rule_name $selected_rule
        }        
        
        return $rule_name
    }
    
    proc generate_vias {layer1 layer2 intersections} {
        variable logical_viarules
        variable physical_viarules

        set vias {}
        set layer1_name $layer1
        set layer2_name $layer2
        regexp {(.*)_PIN_(hor|ver)} $layer1 - layer1_name layer1_direction
        
        set i1 [lsearch $::met_layer_list $layer1_name]
        set i2 [lsearch $::met_layer_list $layer2_name]
        if {$i1 == -1} {puts "Layer1 [dict get $connect layer1], Layer2 $layer2"; exit -1}
        if {$i2 == -1} {puts "Layer1 [dict get $connect layer1], Layer2 $layer2"; exit -1}

	# For each layer between l1 and l2, add vias at the intersection
        foreach intersection $intersections {
            if {![dict exists $logical_viarules [dict get $intersection rule]]} {
                puts "Missing key [dict get $intersection rule]"
                puts "Available keys [dict keys $logical_viarules]"
                exit -1
            }
            set logical_rule [dict get $logical_viarules [dict get $intersection rule]]

            set x [dict get $intersection x]
            set y [dict get $intersection y]
            set width  [dict get $logical_rule width]
            set height  [dict get $logical_rule height]
            
            set connection_layers [list $layer1 {*}[lrange $::met_layer_list [expr $i1 + 1] [expr $i2 - 1]]]
	    foreach lay $connection_layers {
                set via_name [get_via $lay $x $y $width $height]

                lappend vias [list name $via_name lower_layer $lay x [expr round([dict get $intersection x])] y [expr round([dict get $intersection y])]]
	    }
	}
                
        return $vias
    }

## Proc to generate via locations, both for a normal via and stacked via
proc generate_via_stacks {l1 l2 tag grid_data} {
    variable logical_viarules
    variable default_grid_data
    
    set blockage [dict get $grid_data blockage]
    set area [dict get $grid_data area]
    
    #this variable contains locations of intersecting points of two orthogonal metal layers, between which via needs to be inserted
    #for every intersection. Here l1 and l2 are layer names, and i1 and i2 and their indices, tag represents domain (power or ground)	
    set intersections ""
    #check if layer pair is orthogonal, case 1
    set layer1 $l1
    if {[dict exists $grid_data layers $layer1]} {
        set layer1_direction [get_dir $layer1]
        set layer1_width [dict get $grid_data layers $layer1 width]
        set layer1_width [expr round($layer1_width * $::def_units)]
    } elseif {[regexp {(.*)_PIN_(hor|ver)} $l1 - layer1 layer1_direction]} {
        #
    } else {
        puts "Invalid direction for layer $l1"
    }
    
    set layer2 $l2
    if {[dict exists $grid_data layers $layer2]} {
        set layer2_width [dict get $grid_data layers $layer2 width]
        set layer2_width [expr round($layer2_width * $::def_units)]
    } elseif {[dict exists $default_grid_data layers $layer2]} {
        set layer2_width [dict get $default_grid_data layers $layer2 width]
        set layer2_width [expr round($layer2_width * $::def_units)]
    } else {
        puts "No width information available for layer $layer2"
    }
    
    set ignore_count 0
    
    if {$layer1_direction == "hor" && [get_dir $l2] == "ver"} {

        #loop over each stripe of layer 1 and layer 2 
	foreach l1_str $::orig_stripe_locs($l1,$tag) {
	    set a1  [expr {[lindex $l1_str 1]}]

	    foreach l2_str $::orig_stripe_locs($l2,$tag) {
		set flag 1
		set a2	[expr {[lindex $l2_str 0]}]

                # Ignore if outside the area
                if {!($a2 >= [lindex $area 0] && $a2 <= [lindex $area 2] && $a1 >= [lindex $area 1] && $a1 <= [lindex $area 3])} {continue}
	        if {$a2 > [lindex $l1_str 2] || $a2 < [lindex $l1_str 0]} {continue}
	        if {$a1 > [lindex $l2_str 2] || $a1 < [lindex $l2_str 1]} {continue}

                if {[lindex $l2_str 1] == [lindex $area 3]} {continue}
                if {[lindex $l2_str 2] == [lindex $area 1]} {continue}

                #loop over each blockage geometry (macros are blockages)
		foreach blk1 $blockage {
		    set b1 [lindex $blk1 0]
		    set b2 [lindex $blk1 1]
		    set b3 [lindex $blk1 2]
		    set b4 [lindex $blk1 3]
		    ## Check if stripes are to be blocked on these blockages (blockages are specific to each layer). If yes, do not drop vias
		    if {  [lsearch $::macro_blockage_layer_list $l1] >= 0 || [lsearch $::macro_blockage_layer_list $l2] >= 0 } {
			if {($a2 > $b1 && $a2 < $b3 && $a1 > $b2 && $a1 < $b4 ) } {
			    set flag 0
                            break
			} 
			if {$a2 > $b1 && $a2 < $b3 && $a1 == $b2 && $a1 == [lindex $area 1]} {
			    set flag 0
                            break
			} 
			if {$a2 > $b1 && $a2 < $b3 && $a1 == $b4 && $a1 == [lindex $area 3]} {
			    set flag 0
                            break
			} 
		    }
		}

		if {$flag == 1} {
                    ## if no blockage restriction, append intersecting points to this "intersections"
                    if {[regexp {.*_PIN_(hor|ver)} $l1 - dir]} {
                        set layer1_width [lindex $l1_str 3] ; # Already in def units
                    }
                    set rule_name ${l1}${layer2}_${layer2_width}x${layer1_width}
                    if {![dict exists $logical_viarules $rule_name]} {
                        dict set logical_viarules $rule_name [list lower $l1 upper $layer2 width ${layer2_width} height ${layer1_width}]
                    }
		    lappend intersections "rule $rule_name x $a2 y $a1"
		}
	    }
        }

    } elseif {$layer1_direction == "ver" && [get_dir $l2] == "hor"} {
        ##Second case of orthogonal intersection, similar criteria as above, but just flip of coordinates to find intersections
	foreach l1_str $::orig_stripe_locs($l1,$tag) {
	    set n1  [expr {[lindex $l1_str 0]}]
            
	    foreach l2_str $::orig_stripe_locs($l2,$tag) {
		set flag 1
		set n2	[expr {[lindex $l2_str 1]}]
                
                # Ignore if outside the area
                if {!($n1 >= [lindex $area 0] && $n1 <= [lindex $area 2] && $n2 >= [lindex $area 1] && $n2 <= [lindex $area 3])} {continue}
	        if {$n2 > [lindex $l1_str 2] || $n2 < [lindex $l1_str 1]} {continue}
	        if {$n1 > [lindex $l2_str 2] || $n1 < [lindex $l2_str 0]} {continue}
			
		foreach blk1 $blockage {
			set b1 [lindex $blk1 0]
			set b2 [lindex $blk1 1]
			set b3 [lindex $blk1 2]
			set b4 [lindex $blk1 3]
			if {  [lsearch $::macro_blockage_layer_list $l1] >= 0 || [lsearch $::macro_blockage_layer_list $l2] >= 0 } {
				if {($n1 >= $b1 && $n1 <= $b3 && $n2 >= $b2 && $n2 <= $b4)} {
					set flag 0	
				}
			}
		}

		if {$flag == 1} {
                        ## if no blockage restriction, append intersecting points to this "intersections"
                        if {[regexp {.*_PIN_(hor|ver)} $l1 - dir]} {
                            set layer1_width [lindex $l1_str 3] ; # Already in def units
                        }
                        set rule_name ${l1}${layer2}_${layer1_width}x${layer2_width}
                        if {![dict exists $logical_viarules $rule_name]} {
                            dict set logical_viarules $rule_name [list lower $l1 upper $layer2 width ${layer1_width} height ${layer2_width}]
                        }
			lappend intersections "rule $rule_name x $n1 y $n2"
		}


	    }
        }
    } else { 
	#Check if stripes have orthogonal intersections. If not, exit
	puts "ERROR: Adding vias between same direction layers is not supported yet."
        puts "Layer: $l1, Direction: $layer1_direction"
        puts "Layer: $l2, Direction: [get_dir $l2]"
	exit
    }

    return [generate_vias $l1 $l2 $intersections]
}

# proc to generate follow pin layers or standard cell rails

proc generate_lower_metal_followpin_rails {tag area} {
	#Assumes horizontal stripes
	set lay $::rails_mlayer

	if {$tag == $::rails_start_with} { ;#If starting from bottom with this net, 
		set lly [lindex $area 1]
	} else {
		set lly [expr {[lindex $area 1] + $::row_height}]
	}
	lappend ::stripe_locs($lay,$tag) "[lindex $area 0] $lly [lindex $area 2]"
	lappend ::orig_stripe_locs($lay,$tag) "[lindex $area 0] $lly [lindex $area 2]"


	#Rail every alternate rows - Assuming horizontal rows and full width rails
	for {set y [expr {$lly + (2 * $::row_height)}]} {$y <= [lindex $area 3]} {set y [expr {$y + (2 * $::row_height)}]} {
	    lappend ::stripe_locs($lay,$tag) "[lindex $area 0] $y [lindex $area 2]"
	    lappend ::orig_stripe_locs($lay,$tag) "[lindex $area 0] $y [lindex $area 2]"
	}
}


# proc for creating pdn mesh for upper metal layers
proc generate_upper_metal_mesh_stripes {tag layer area} {
    variable widths
    variable pitches
    variable loffset
    variable boffset

	if {[get_dir $layer] == "hor"} {
		set offset [expr [lindex $area 1] + $boffset($layer)]
		if {$tag != $::stripes_start_with} { ;#If not starting from bottom with this net, 
			set offset [expr {$offset + ($pitches($layer) / 2)}]
		}
		for {set y $offset} {$y < [expr {[lindex $area 3] - $widths($layer)}]} {set y [expr {$pitches($layer) + $y}]} {
			lappend ::stripe_locs($layer,$tag) "[lindex $area 0] $y [lindex $area 2]"
			lappend ::orig_stripe_locs($layer,$tag) "[lindex $area 0] $y [lindex $area 2]"
		
		}
	} elseif {[get_dir $layer] == "ver"} {
		set offset [expr [lindex $area 0] + $loffset($layer)]

		if {$tag != $::stripes_start_with} { ;#If not starting from bottom with this net, 
			set offset [expr {$offset + ($pitches($layer) / 2)}]
		}
		for {set x $offset} {$x < [expr {[lindex $area 2] - $widths($layer)}]} {set x [expr {$pitches($layer) + $x}]} {
			lappend ::stripe_locs($layer,$tag) "$x [lindex $area 1] [lindex $area 3]"
			lappend ::orig_stripe_locs($layer,$tag) "$x [lindex $area 1] [lindex $area 3]"
		}
	} else {
		puts "ERROR: Invalid direction \"[get_dir $layer]\" for metal layer ${layer}. Should be either \"hor\" or \"ver\". EXITING....."
		exit
	}
}

# this proc chops down metal stripes wherever they are to be blocked
# inputs to this proc are layer name, domain (tag), and blockage bbox cooridnates

proc generate_metal_with_blockage {layer area tag b1 b2 b3 b4} {
	set ::temp_locs($layer,$tag) ""
	set ::temp_locs($layer,$tag) $::stripe_locs($layer,$tag)
	set ::stripe_locs($layer,$tag) ""
	foreach l_str $::temp_locs($layer,$tag) {
		set loc1 [lindex $l_str 0]
		set loc2 [lindex $l_str 1]
		set loc3 [lindex $l_str 2]
		location_stripe_blockage $loc1 $loc2 $loc3 $layer $area $tag $b1 $b2 $b3 $b4
	}
		
        set ::stripe_locs($layer,$tag) [lsort -unique $::stripe_locs($layer,$tag)]
}

# sub proc called from previous proc
proc location_stripe_blockage {loc1 loc2 loc3 lay area tag b1 b2 b3 b4} {
    variable widths

        set area_llx [lindex $area 0]
        set area_lly [lindex $area 1]
        set area_urx [lindex $area 2]
        set area_ury [lindex $area 3]

	if {[get_dir $lay] == "hor"} {
		##Check if stripe is passing through blockage
		##puts "HORIZONTAL BLOCKAGE "
		set x1 $loc1
		set y1 [expr max($loc2 - $widths($lay)/2, [lindex $area 1])]
		set x2 $loc3
		set y2 [expr min($y1 +  $widths($lay),[lindex $area 3])]
                #puts "segment:  [format {%9.1f %9.1f} $loc1 $loc3]"              
                #puts "blockage: [format {%9.1f %9.1f} $b1 $b3]"
		if {  ($y1 >= $b2) && ($y2 <= $b4) && ( ($x1 <= $b3 && $x2 >= $b3) || ($x1 <= $b1 && $x2 >= $b1)  || ($x1 <= $b1 && $x2 >= $b3) || ($x1 <= $b3 && $x2 >= $b1) )  } {

			if {$x1 <= $b1 && $x2 >= $b3} {	
				#puts "  CASE3 of blockage in between left and right edge of core, cut the stripe into two segments"
                                #puts "    $x1 $loc2 $b1"
                                #puts "    $b3 $loc2 $x2"
				lappend ::stripe_locs($lay,$tag) "$x1 $loc2 $b1"
				lappend ::stripe_locs($lay,$tag) "$b3 $loc2 $x2"	
			} elseif {$x1 <= $b3 && $x2 >= $b3} {	
				#puts "  CASE3 of blockage in between left and right edge of core, but stripe extending out only in one side (right)"
                                #puts "    $b3 $loc2 $x2"
				lappend ::stripe_locs($lay,$tag) "$b3 $loc2 $x2"	
			} elseif {$x1 <= $b1 && $x2 >= $b1} {	
				#puts "  CASE3 of blockage in between left and right edge of core, but stripe extending out only in one side (left)"
                                #puts "    $x1 $loc2 $b1"
				lappend ::stripe_locs($lay,$tag) "$x1 $loc2 $b1"
			} else {
                            #puts "  CASE5 no match - eliminated segment"
                            #puts "    $loc1 $loc2 $loc3"
                        }
		} else {
			lappend ::stripe_locs($lay,$tag) "$x1 $loc2 $x2"
			#puts "stripe does not pass thru any layer blockage --- CASE 4 (do not change the stripe location)"
		}
	}

	if {[get_dir $lay] == "ver"} {
		##Check if veritcal stripe is passing through blockage, same strategy as above
		set x1 $loc1 ;# [expr max($loc1 -  $widths($lay)/2, [lindex $area 0])]
		set y1 $loc2
		set x2 $loc1 ;# [expr min($loc1 +  $widths($lay)/2, [lindex $area 2])]
		set y2 $loc3

		if {$x2 > $b1 && $x1 < $b3} {

			if {$y1 <= $b2 && $y2 >= $b4} {	
				##puts "CASE3 of blockage in between top and bottom edge of core, cut the stripe into two segments
				lappend ::stripe_locs($lay,$tag) "$loc1 $y1 $b2"
				lappend ::stripe_locs($lay,$tag) "$loc1 $b4 $y2"	
			} elseif {$y1 <= $b4 && $y2 >= $b4} {	
				##puts "CASE3 of blockage in between top and bottom edge of core, but stripe extending out only in one side (right)"
				lappend ::stripe_locs($lay,$tag) "$loc1 $b4 $y2"	
			} elseif {$y1 <= $b2 && $y2 >= $b2} {	
				##puts "CASE3 of blockage in between top and bottom edge of core, but stripe extending out only in one side (left)"
				lappend ::stripe_locs($lay,$tag) "$loc1 $y1 $b2"
			} elseif {$y1 <= $b4 && $y1 >= $b2 && $y2 >= $b2 && $y2 <= $b4} {	
                                ##completely enclosed - remove segment
			} else {
                            #puts "  CASE5 no match"
                            #puts "    $loc1 $loc2 $loc3"
			    lappend ::stripe_locs($lay,$tag) "$loc1 $y1 $y2"
                        }
		} else {
			lappend ::stripe_locs($lay,$tag) "$loc1 $y1 $y2"
		}
	}
}


## this is a top-level proc to generate PDN stripes and insert vias between these stripes
proc generate_stripes_vias {tag net_name grid_data} {
        variable vias
        
        set area [dict get $grid_data area]
        set blockage [dict get $grid_data blockage]

	##puts -nonewline "Adding stripes for $net_name ..."
	foreach lay [dict keys [dict get $grid_data layers]] {

	    if {$lay == $::rails_mlayer} {
	        #Std. cell rails
	        generate_lower_metal_followpin_rails $tag $area

	        foreach blk1 $blockage {
		        set b1 [lindex $blk1 0]
		        set b2 [lindex $blk1 1]
		        set b3 [lindex $blk1 2]
		        set b4 [lindex $blk1 3]
		        generate_metal_with_blockage $::rails_mlayer $area $tag $b1 $b2 $b3 $b4
	        }

            } else {
	        #Upper layer stripes
		generate_upper_metal_mesh_stripes $tag $lay $area

		if {  [lsearch $::macro_blockage_layer_list $lay] >= 0 } {
			foreach blk2 $blockage {
				set c1 [lindex $blk2 0]
				set c2 [lindex $blk2 1]
				set c3 [lindex $blk2 2]
				set c4 [lindex $blk2 3]

				generate_metal_with_blockage $lay $area $tag $c1 $c2 $c3 $c4
			}
		}
	    }
	}

	#Via stacks
	##puts -nonewline "Adding vias for $net_name ..."
	foreach tuple [dict get $grid_data connect] {
		set l1 [lindex $tuple 0]
		set l2 [lindex $tuple 1]

                set connections [generate_via_stacks $l1 $l2 $tag $grid_data]
		lappend vias [list net_name $net_name connections $connections]
	}
	##puts " DONE \[Total elapsed walltime = [expr {[expr {[clock clicks -milliseconds] - $::start_time}]/1000.0}] seconds\]"

}

    namespace export write_def write_vias
}
