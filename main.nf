#!/usr/bin/env nextflow

if(params.help) {
    usage = file("$baseDir/USAGE")

    cpu_count = Runtime.runtime.availableProcessors()
    bindings = ["atlas_anat":"$params.atlas_anat",
                "atlas_directory":"$params.atlas_directory",
                "atlas_bundles_basename":"$params.atlas_bundles_basename",
                "use_orientational_priors":"$params.use_orientational_priors",
                "use_bs_tracking_mask":"$params.use_bs_tracking_mask",
                "bs_tracking_mask_dilation":"$params.bs_tracking_mask_dilation",
                "use_bs_endpoints_mask":"$params.use_bs_endpoints_mask",
                "bs_endpoints_mask_dilation":"$params.bs_endpoints_mask_dilation",
                "use_tracking_mask_as_seeding":"$params.use_tracking_mask_as_seeding",
                "local_tracking":"$params.local_tracking",
                "pft_tracking":"$params.pft_tracking",
                "seeding":"$params.seeding",
                "nbr_seeds":"$params.nbr_seeds",
                "algo":"$params.algo",
                "basis":"$params.basis",
                "min_length":"$params.min_length",
                "max_length":"$params.max_length",
                "compress_error_tolerance":"$params.compress_error_tolerance",
                "tracking_seed":"$params.tracking_seed",
                "recobundle":"$params.recobundle",
                "wb_clustering_thr":"$params.wb_clustering_thr",
                "model_clustering_thr":"$params.model_clustering_thr",
                "prunning_thr":"$params.prunning_thr",
                "outlier_alpha":"$params.outlier_alpha"
                ]
    engine = new groovy.text.SimpleTemplateEngine()
    template = engine.createTemplate(usage.text).make(bindings)
    print template.toString()
    return
}

log.info "SCIL bundle specific pipeline"
log.info "=============================="
log.info ""
log.info "Start time: $workflow.start"
log.info ""

log.debug "[Command-line]"
log.debug "$workflow.commandLine"
log.debug ""

log.info "[Git Info]"
log.info "$workflow.repository - $workflow.revision [$workflow.commitId]"
log.info ""

log.info "Options"
log.info "======="
log.info ""
log.info "[Atlas]"
log.info "Atlas anatomy: $params.atlas_anat"
log.info "Atlas directory: $params.atlas_directory"
log.info "Atlas bundles: $params.atlas_bundles_basename"
log.info ""
log.info "[Priors options]"
log.info "BS Tracking Mask: $params.use_bs_tracking_mask"
log.info "BS Endpoints Mask: $params.use_bs_endpoints_mask"
log.info "Endpoints Mask Dilation: $params.bs_endpoints_mask_dilation"
log.info "Seeding From Tracking Mask: $params.use_tracking_mask_as_seeding"
log.info "Tracking Mask Dilation: $params.bs_tracking_mask_dilation"
log.info ""
log.info "[Tracking options]"
log.info "Local Tracking: $params.local_tracking"
log.info "PFT Tracking: $params.pft_tracking"
log.info "Algo: $params.algo"
log.info "Seeding type: $params.seeding"
log.info "Number of seeds: $params.nbr_seeds"
log.info "Random seed: $params.tracking_seed"
log.info "Minimum length: $params.min_length"
log.info "Maximum length: $params.max_length"
log.info "Compressing threshold: $params.compress_error_tolerance"
log.info ""
log.info "[Recobundles options]"
log.info "Segmentation with Recobundle: $params.recobundle"
log.info "Whole Brain Clustering Threshold: $params.wb_clustering_thr"
log.info "Model Clustering Threshold: $params.model_clustering_thr"
log.info "Prunning Threshold: $params.prunning_thr"
log.info "Outlier Removal Alpha: $params.outlier_alpha"
log.info ""
log.info ""

if (params.root)
{
    log.info "Input: $params.root"
    root = file(params.root)
    /* Watch out, files are ordered alphabetically in channel */
        in_data = Channel
            .fromFilePairs("$root/**/{*fa*.nii.gz,*fodf*.nii.gz,*tracking_mask*.nii.gz}",
                           size: 3,
                           maxDepth:2,
                           flat: true) {it.parent.name}

        map_pft = Channel
            .fromFilePairs("$root/**/{*map_exclude*.nii.gz,*map_include*.nii.gz}",
                           size: 2,
                           maxDepth:2,
                           flat: true) {it.parent.name}

        exclusion_data = Channel
            .fromFilePairs("$root/**/{*exclusion_mask*.nii.gz}",
                           size: 1,
                           maxDepth:2,
                           flat: true) {it.parent.name}
}

(anat_for_registration, anat_for_deformation, fod_and_mask_for_priors) = in_data
    .map{sid, anat, fodf, tracking_mask -> 
        [tuple(sid, anat),
        tuple(sid, anat),
        tuple(sid, fodf, tracking_mask)]}
    .separate(3)

(map_in_for_tracking, map_ex_for_tracking) = map_pft
    .map{sid, map_exclude , map_include -> 
        [tuple(sid, map_include),
        tuple(sid, map_exclude)]}
    .separate(2)

(masks_for_exclusion) = exclusion_data
    .map{sid, mask -> 
        [tuple(sid, mask)]}
    .separate(1)

atlas_directory = file(params.atlas_directory)
atlas_bundles = params.atlas_bundles_basename?.tokenize(',')
algo_list = params.algo?.tokenize(',')

workflow.onComplete {
    log.info "Pipeline completed at: $workflow.complete"
    log.info "Execution status: ${ workflow.success ? 'OK' : 'failed' }"
    log.info "Execution duration: $workflow.duration"
}

process Register_Anat {
    cpus params.register_processes
    input:
    set sid, file(native_anat) from anat_for_registration

    output:
    set sid, "${sid}__output1InverseWarp.nii.gz", "${sid}__output0GenericAffine.mat" into deformation_for_warping
    file "${sid}__outputWarped.nii.gz"
    script:
    """
    antsRegistrationSyNQuick.sh -d 3 -f ${native_anat} -m ${params.atlas_anat} -n ${params.register_processes} -o ${sid}__output
    """ 
}


anat_for_deformation
    .join(deformation_for_warping)
    .set{anat_deformation_for_warp}
process Warp_Bundle {
    cpus 2
    input:
    set sid, file(anat), file(warp), file(affine) from anat_deformation_for_warp
    each bundle_name from atlas_bundles

    output:
    set sid, val(bundle_name), "${sid}__${bundle_name}_warp.trk" into bundles_for_priors, models_for_recobundle
    script:
    """
    ConvertTransformFile 3 ${affine} ${affine}.txt --hm --ras
    scil_apply_transform_to_tractogram.py ${params.atlas_directory}/${bundle_name}.trk ${warp} ${affine}.txt ${bundle_name}_linear.trk --inverse -f
    scil_apply_warp_to_tractogram.py ${bundle_name}_linear.trk ${anat} ${warp} ${bundle_name}_warp.trk -f
    scil_remove_invalid_streamlines.py ${bundle_name}_warp.trk ${bundle_name}_ic.trk

    mv ${bundle_name}_ic.trk "${sid}__${bundle_name}_warp.trk"
    """ 
}


fod_and_mask_for_priors
    .combine(bundles_for_priors, by: 0)
    .set{fod_mask_bundles_for_priors}
process Generate_Priors {
    cpus 2
    errorStrategy 'ignore'
    publishDir = {"./results_bst/$sid/$task.process/${bundle_name}"}
    input:
    set sid, file(fod), file(mask), val(bundle_name), file(bundle) from fod_mask_bundles_for_priors

    output:
    set sid, val(bundle_name), "${sid}__${bundle_name}_efod.nii.gz" into efod_for_tracking
    set sid, val(bundle_name), "${fod}" into fod_for_tracking
    set sid, "${sid}__${bundle_name}_priors.nii.gz"
    set sid, val(bundle_name), "${sid}__${bundle_name}_todi_mask_dilate.nii.gz", \
        "${sid}__${bundle_name}_endpoints_mask_dilate.nii.gz" into masks_for_seeding
    set sid, val(bundle_name), "${mask}", "${sid}__${bundle_name}_todi_mask_dilate.nii.gz" into masks_for_tracking
    set sid, val(bundle_name), "${sid}__${bundle_name}_todi_mask_dilate.nii.gz" into masks_for_map_ex
    set sid, val(bundle_name), "${sid}__${bundle_name}_endpoints_mask_dilate.nii.gz" into masks_for_map_in
    script:
    """
    scil_generate_priors_from_bundle.py ${bundle} ${fod} ${mask} \
        --sh_basis $params.basis --output_prefix ${sid}__${bundle_name}_
    maskfilter ${sid}__${bundle_name}_todi_mask.nii.gz \
        dilate dilate_todi.nii.gz -npass $params.bs_tracking_mask_dilation
    scil_mask_math.py intersection ${mask} dilate_todi.nii.gz \
        ${sid}__${bundle_name}_todi_mask_dilate.nii.gz

    maskfilter ${sid}__${bundle_name}_endpoints_mask.nii.gz \
        dilate dilate_endpoints.nii.gz -npass $params.bs_endpoints_mask_dilation
    scil_mask_math.py intersection ${mask} dilate_endpoints.nii.gz \
        ${sid}__${bundle_name}_endpoints_mask_dilate.nii.gz
    """
}

process Seeding_Mask {
    cpus 1
    input:
    set sid, val(bundle_name), file(tracking_mask), file(endpoints_mask) from masks_for_seeding

    output:
    set sid, val(bundle_name), "${sid}__${bundle_name}_seeding_mask.nii.gz" into \
        seeding_mask_for_PFT_tracking, seeding_mask_for_local_tracking
    script:
    if (params.use_tracking_mask_as_seeding)
        """
        mv ${tracking_mask} ${sid}__${bundle_name}_seeding_mask.nii.gz
        """
    else
        """
        mv ${endpoints_mask} ${sid}__${bundle_name}_seeding_mask.nii.gz
        """
}

process Tracking_Mask {
    cpus 1
    input:
    set sid, val(bundle_name), file(tracking_mask), file(bs_mask) from masks_for_tracking

    output:
    set sid, val(bundle_name), "${sid}__${bundle_name}_tracking_mask.nii.gz" \
        into tracking_mask_for_local_tracking
    when: 
    params.local_tracking
    script:
    if (params.use_bs_tracking_mask)
        """
        mv ${bs_mask} ${sid}__${bundle_name}_tracking_mask.nii.gz
        """
    else
        """
        mv ${tracking_mask} ${sid}__${bundle_name}_tracking_mask.nii.gz
        """
}

if (params.use_orientational_priors)
    efod_for_tracking
        .into{fod_for_local_tracking; fod_for_PFT_tracking} 
else
    fod_for_tracking
        .into{fod_for_local_tracking; fod_for_PFT_tracking}
tracking_mask_for_local_tracking
    .combine(fod_for_local_tracking, by: [0,1])
    .combine(seeding_mask_for_local_tracking, by: [0,1])
    .set{mask_seeding_mask_fod_for_tracking}
process Local_Tracking {
    cpus 2
    input:
    set sid, val(bundle_name), file(tracking_mask), file(efod), file(seeding_mask) \
        from mask_seeding_mask_fod_for_tracking
    each algo from algo_list

    output:
    set sid, val(bundle_name), val(algo), val('local'), \
        "${sid}__${bundle_name}_${algo}_${params.seeding}_${params.nbr_seeds}.trk" into \
            local_bundles_for_exclusion
    when: 
    params.local_tracking
    script:
    """
    scil_compute_local_tracking.py ${efod} ${seeding_mask} ${tracking_mask} \
        ${sid}__${bundle_name}_${algo}_${params.seeding}_${params.nbr_seeds}.trk \
        --sh_basis $params.basis --min_len $params.min_length --max_len $params.max_length \
        --$params.seeding $params.nbr_seeds --compress $params.compress_error_tolerance \
        --seed $params.tracking_seed --algo ${algo}
    """
}

map_in_for_tracking
    .combine(masks_for_map_in, by: 0)
    .set{masks_map_in_for_bs}
process Generate_Map_Include {
    cpus 1
    input:
    set sid, file(map_include), val(bundle_name), file(endpoints_mask) from masks_map_in_for_bs

    output:
    set sid, val(bundle_name), "${sid}__${bundle_name}_map_include.nii.gz" into map_in_for_PFT_tracking
    when: 
    params.pft_tracking
    script:
    if (params.use_bs_endpoints_mask)
        """
        maskfilter ${endpoints_mask} dilate dilate_endpoints.nii.gz \
            -npass $params.bs_endpoints_mask_dilation
        scil_mask_math.py intersection dilate_endpoints.nii.gz ${map_include} \
            ${sid}__${bundle_name}_map_include.nii.gz
        """
    else
        """
        mv $map_include ${sid}__${bundle_name}_map_include.nii.gz
        """ 
}

map_ex_for_tracking
    .combine(masks_for_map_ex, by: 0)
    .set{masks_map_ex_for_bs}
process Generate_Map_Exclude {
    cpus 1
    input:
    set sid, file(map_exclude), val(bundle_name), file(tracking_mask) from masks_map_ex_for_bs

    output:
    set sid, val(bundle_name), "${sid}__${bundle_name}_map_exclude.nii.gz" into \
        map_ex_for_PFT_tracking
    when: 
    params.pft_tracking
    script:
    if (params.use_bs_tracking_mask)
        """
        mrthreshold ${tracking_mask} inverted_mask.nii.gz
        
        mrcalc ${map_exclude} inverted_mask.nii.gz \
            -mult ${sid}__${bundle_name}_map_exclude.nii.gz
        """
    else
        """
        mv ${map_exclude} ${sid}__${bundle_name}_map_exclude.nii.gz
        """
}

map_ex_for_PFT_tracking
    .combine(map_in_for_PFT_tracking, by: [0,1])
    .combine(fod_for_PFT_tracking, by: [0,1])
    .combine(seeding_mask_for_PFT_tracking, by: [0,1])
    .set{maps_seeding_mask_fod_for_tracking}
process PFT_Tracking {
    cpus 2
    input:
    set sid, val(bundle_name), file(map_exclude), file(map_include), file(efod), \
        file(seeding_mask) from maps_seeding_mask_fod_for_tracking
    each algo from algo_list

    output:
    set sid, val(bundle_name), val(algo), val('pft'), \
        "${sid}__${bundle_name}_${algo}_${params.seeding}_${params.nbr_seeds}.trk" into \
        pft_bundles_for_exclusion
    when: 
    params.pft_tracking
    script:
    seeding = params.seeding == 'nts' ? 'nt' : params.seeding
    """
    scil_compute_pft.py ${efod} ${seeding_mask} ${map_include} ${map_exclude} \
        ${sid}__${bundle_name}_${algo}_${params.seeding}_${params.nbr_seeds}.trk \
        --algo $algo --sh_basis $params.basis --min_length $params.min_length \
        --max_length $params.max_length --$seeding $params.nbr_seeds \
        --compress $params.compress_error_tolerance --seed $params.tracking_seed
    """
}

local_bundles_for_exclusion
    .concat(pft_bundles_for_exclusion)
    .set{bundles_for_masking}
bundles_for_masking
    .combine(masks_for_exclusion, by: 0)
    .set{bundles_masks_for_masking}
process Mask_Exclusion{
    cpus 1
    publishDir = {"./results_bst/$sid/$task.process/${bundle_name}"}
    input:
    set sid, val(bundle_name), val(algo), val(tracking_source), file(bundle), file(mask) from \
        bundles_masks_for_masking

    output:
    set sid, val(bundle_name), val(algo), val(tracking_source), "${sid}__${bundle_name}_${algo}_${tracking_source}_masked.trk" into bundles_for_recobundle
    script:
    """
    scil_filter_tractogram.py ${bundle} ${sid}__${bundle_name}_${algo}_${tracking_source}_masked.trk --drawn_roi ${mask} any exclude
    """
}

bundles_for_recobundle
    .combine(models_for_recobundle, by: [0,1])
    .set{bundles_models_for_recobundle}
process Recobundle_Segmentation {
    cpus 1
    publishDir = {"./results_bst/$sid/$task.process/${bundle_name}"}
    input:
    set sid, val(bundle_name), val(algo), val(tracking_source), file(bundle), file(model) from \
        bundles_models_for_recobundle

    output:
    set sid, val(bundle_name), val(algo), val(tracking_source), "${sid}__${bundle_name}_${algo}_${tracking_source}_segmented.trk" into bundles_for_outliers
    when: 
    params.recobundle
    script:
    """
    printf "1 0 0 0\n0 1 0 0\n0 0 1 0\n0 0 0 1" >> identity.txt
    scil_recognize_single_bundle.py ${bundle} ${model} identity.txt \
        ${sid}__${bundle_name}_${algo}_${tracking_source}_segmented.trk \
        --wb_clustering_thr $params.wb_clustering_thr \
        --model_clustering_thr $params.model_clustering_thr \
        --slr_threads 1 --pruning_thr $params.prunning_thr
    """
}

process Outliers_Removal {
    cpus 1
    publishDir = {"./results_bst/$sid/$task.process/${bundle_name}"}
    errorStrategy 'ignore'
    input:
    set sid, val(bundle_name), val(algo), val(tracking_source), file(bundle) from \
        bundles_for_outliers

    output:
    file "${sid}__${bundle_name}_${algo}_${tracking_source}_cleaned.trk"
    when: 
    params.recobundle
    script:
    """
    scil_outlier_rejection.py ${bundle} \
        ${sid}__${bundle_name}_${algo}_${tracking_source}_cleaned.trk \
        outliers.trk --alpha $params.outlier_alpha
    """
}