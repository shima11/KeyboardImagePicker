//
//  ViewController.swift
//  KeyboardImagePicker
//
//  Created by jinsei_shima on 2019/02/09.
//  Copyright © 2019 Jinsei Shima. All rights reserved.
//

import UIKit
import Photos

import RxKeyboard
import RxSwift

final class ImagePickerCarouselView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {

    private let collectionView: UICollectionView

    private let imageManager = PHImageManager()

    private var items: [PHAsset] = []

    override init(frame: CGRect) {

        let layout = UICollectionViewFlowLayout()
        layout.itemSize = .init(width: 80, height: 80)
        layout.sectionInset = .init(top: 8, left: 8, bottom: 8, right: 8)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.alwaysBounceHorizontal = true

        super.init(frame: frame)

        backgroundColor = .white
        collectionView.backgroundColor = .white

        addSubview(collectionView)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        collectionView.dataSource = self
        collectionView.delegate = self

        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")

        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        setup()
    }

    private func setup() {

        libraryRequestAuthorization()

        let result = PHAsset.fetchAssets(with: .image, options: nil)
        result.enumerateObjects { [weak self] (obj, index, stop) in
            self?.items.append(obj)
        }

        collectionView.reloadData()
    }

    // カメラロールへのアクセス許可
    fileprivate func libraryRequestAuthorization() {
        PHPhotoLibrary.requestAuthorization({ status in
            switch status {
            case .authorized:
                print("authorized")
            case .denied:
                print("denied")
            case .notDetermined:
                print("NotDetermined")
            case .restricted:
                print("Restricted")
            }
        })
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
//        let item = items[indexPath.row]
        cell.backgroundColor = .darkGray
        return cell
    }


    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class MessageView: UIView, UITextViewDelegate {

    private let libraryButton = UIButton(type: .system)
    private let cameraButton = UIButton(type: .system)
    private let textView = UITextView()
    private let sendButton = UIButton(type: .system)

    private let imagePickerCarouselView = ImagePickerCarouselView(frame: .zero)

    override var canBecomeFirstResponder: Bool {
        return true
    }

    enum KeyboardType {
        case keyboard, imagePicker
    }

    var keyboardType: KeyboardType = .keyboard {
        didSet {
            reloadInputViews()
        }
    }

    override var inputView: UIView? {
        switch keyboardType {
        case .keyboard:
            return nil
        case .imagePicker:
            return imagePickerCarouselView
        }
    }

    @objc func tapLibraryButton() {

        keyboardType = .imagePicker

        becomeFirstResponder()
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {

        keyboardType = .keyboard

        return true
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .white

        addSubview(cameraButton)
        addSubview(libraryButton)
        addSubview(textView)
        addSubview(sendButton)

        cameraButton.setImage(UIImage.init(named: "camera"), for: .normal)
        cameraButton.translatesAutoresizingMaskIntoConstraints = false

        libraryButton.setImage(UIImage.init(named: "library"), for: .normal)
        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.addTarget(self, action: #selector(tapLibraryButton), for: .touchUpInside)

        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = UIFont.systemFont(ofSize: 18, weight: .regular)

        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        sendButton.translatesAutoresizingMaskIntoConstraints = false


        [
            cameraButton.leftAnchor.constraint(equalTo: leftAnchor, constant: 16),
            cameraButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            libraryButton.leftAnchor.constraint(equalTo: cameraButton.rightAnchor, constant: 8.0),
            libraryButton.centerYAnchor.constraint(equalTo: cameraButton.centerYAnchor),

            textView.leftAnchor.constraint(equalTo: libraryButton.rightAnchor, constant: 8),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            sendButton.leftAnchor.constraint(equalTo: textView.rightAnchor, constant: 8),
            sendButton.centerYAnchor.constraint(equalTo: cameraButton.centerYAnchor),
            sendButton.rightAnchor.constraint(equalTo: rightAnchor, constant: -16)
            ]
            .forEach { $0.isActive = true }

    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}



class ViewController: UIViewController {

    private let disposeBag = DisposeBag()

    private let messageInputView = MessageView(frame: .zero)


    @objc func tap() {
        messageInputView.endEditing(false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.groupTableViewBackground


        view.addSubview(messageInputView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(tap))
        view.addGestureRecognizer(tapGesture)

        messageInputView.translatesAutoresizingMaskIntoConstraints = false

        [
            messageInputView.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 0),
            messageInputView.rightAnchor.constraint(equalTo: view.rightAnchor, constant: 0),
            messageInputView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 0)
            ]
            .forEach { $0.isActive = true }


        var constraint1: NSLayoutConstraint? = nil
        var constraint2: NSLayoutConstraint? = nil

        RxKeyboard
            .instance
            .visibleHeight
            .drive(onNext: { [weak self] keyboardVisibleHeight in

                guard let self = self else { return }

                constraint1?.isActive = false
                constraint1 = nil

                constraint2?.isActive = false
                constraint2 = nil

                if keyboardVisibleHeight <= 0 {
                    constraint1 = self.messageInputView.bottomAnchor.constraint(
                        equalTo: self.view.safeAreaLayoutGuide.bottomAnchor,
                        constant: -keyboardVisibleHeight
                        )
                } else {
                    constraint2 = self.messageInputView.bottomAnchor.constraint(
                        equalTo: self.view.bottomAnchor,
                        constant: -keyboardVisibleHeight
                        )
                }
                constraint1?.isActive = true
                constraint2?.isActive = true

                self.view.layoutIfNeeded()

            })
            .disposed(by: disposeBag)

    }


}

